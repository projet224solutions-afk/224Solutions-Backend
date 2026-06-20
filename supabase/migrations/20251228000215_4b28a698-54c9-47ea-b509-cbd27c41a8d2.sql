-- =============================================
-- SYSTÈME MULTI-DEVISES - MIGRATION COMPLÈTE
-- =============================================

-- 1. Ajouter les champs country et language aux profiles
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS detected_country VARCHAR(3),
ADD COLUMN IF NOT EXISTS detected_currency VARCHAR(3) DEFAULT 'GNF',
ADD COLUMN IF NOT EXISTS detected_language VARCHAR(5) DEFAULT 'fr',
ADD COLUMN IF NOT EXISTS geo_detection_method VARCHAR(50),
ADD COLUMN IF NOT EXISTS last_geo_update TIMESTAMP WITH TIME ZONE;

-- 2. Mettre à jour la table exchange_rates avec rate_internal et security_margin
ALTER TABLE public.exchange_rates 
ADD COLUMN IF NOT EXISTS rate_internal NUMERIC DEFAULT 0,
ADD COLUMN IF NOT EXISTS security_margin NUMERIC DEFAULT 0.005,
ADD COLUMN IF NOT EXISTS source VARCHAR(100) DEFAULT 'open.er-api.com';

-- 3. Créer la table des frais de transfert
CREATE TABLE IF NOT EXISTS public.transfer_fees (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  country_from VARCHAR(3),
  country_to VARCHAR(3),
  currency_from VARCHAR(3),
  currency_to VARCHAR(3),
  min_amount NUMERIC DEFAULT 0,
  max_amount NUMERIC,
  fee_percentage NUMERIC NOT NULL DEFAULT 1.5,
  fee_fixed NUMERIC DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  created_by UUID REFERENCES auth.users(id)
);

-- 4. Créer la table des transferts wallet-to-wallet
CREATE TABLE IF NOT EXISTS public.wallet_transfers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_code VARCHAR(50) UNIQUE NOT NULL,
  sender_id UUID NOT NULL REFERENCES auth.users(id),
  receiver_id UUID NOT NULL REFERENCES auth.users(id),
  sender_wallet_id UUID REFERENCES public.wallets(id),
  receiver_wallet_id UUID REFERENCES public.wallets(id),
  
  -- Montants et devises
  amount_sent NUMERIC NOT NULL,
  currency_sent VARCHAR(3) NOT NULL,
  fee_percentage NUMERIC NOT NULL DEFAULT 0,
  fee_amount NUMERIC NOT NULL DEFAULT 0,
  amount_after_fee NUMERIC NOT NULL,
  
  -- Taux de change
  rate_displayed NUMERIC NOT NULL DEFAULT 1,
  rate_used NUMERIC NOT NULL DEFAULT 1,
  security_margin_applied NUMERIC DEFAULT 0.005,
  
  -- Montant reçu
  amount_received NUMERIC NOT NULL,
  currency_received VARCHAR(3) NOT NULL,
  
  -- Métadonnées
  transfer_type VARCHAR(50) DEFAULT 'WALLET_TO_WALLET',
  description TEXT,
  status VARCHAR(30) DEFAULT 'pending',
  
  -- Géolocalisation
  sender_country VARCHAR(3),
  receiver_country VARCHAR(3),
  
  -- Audit
  ip_address VARCHAR(50),
  user_agent TEXT,
  
  -- Timestamps
  initiated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  confirmed_at TIMESTAMP WITH TIME ZONE,
  completed_at TIMESTAMP WITH TIME ZONE,
  failed_at TIMESTAMP WITH TIME ZONE,
  failure_reason TEXT,
  
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 5. Index pour les performances
CREATE INDEX IF NOT EXISTS idx_wallet_transfers_sender ON public.wallet_transfers(sender_id);
CREATE INDEX IF NOT EXISTS idx_wallet_transfers_receiver ON public.wallet_transfers(receiver_id);
CREATE INDEX IF NOT EXISTS idx_wallet_transfers_status ON public.wallet_transfers(status);
CREATE INDEX IF NOT EXISTS idx_wallet_transfers_code ON public.wallet_transfers(transfer_code);
CREATE INDEX IF NOT EXISTS idx_transfer_fees_currencies ON public.transfer_fees(currency_from, currency_to);

-- 6. Enable RLS
ALTER TABLE public.transfer_fees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_transfers ENABLE ROW LEVEL SECURITY;

-- 7. RLS Policies pour transfer_fees (lecture publique)
DROP POLICY IF EXISTS "Anyone can read active transfer fees" ON public.transfer_fees;
CREATE POLICY "Anyone can read active transfer fees"
ON public.transfer_fees FOR SELECT
USING (is_active = true);

DROP POLICY IF EXISTS "Admins can manage transfer fees" ON public.transfer_fees;
CREATE POLICY "Admins can manage transfer fees"
ON public.transfer_fees FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM public.profiles p 
    WHERE p.id = auth.uid() 
    AND p.role = 'admin'
  )
);

-- 8. RLS Policies pour wallet_transfers
DROP POLICY IF EXISTS "Users can view their own transfers" ON public.wallet_transfers;
CREATE POLICY "Users can view their own transfers"
ON public.wallet_transfers FOR SELECT
USING (auth.uid() = sender_id OR auth.uid() = receiver_id);

DROP POLICY IF EXISTS "Users can create transfers from their wallet" ON public.wallet_transfers;
CREATE POLICY "Users can create transfers from their wallet"
ON public.wallet_transfers FOR INSERT
WITH CHECK (auth.uid() = sender_id);

-- 9. Fonction pour calculer les frais
CREATE OR REPLACE FUNCTION public.calculate_transfer_fee(
  p_amount NUMERIC,
  p_currency_from VARCHAR,
  p_currency_to VARCHAR,
  p_country_from VARCHAR DEFAULT NULL,
  p_country_to VARCHAR DEFAULT NULL
)
RETURNS TABLE(
  fee_percentage NUMERIC,
  fee_amount NUMERIC,
  amount_after_fee NUMERIC
) AS $$
DECLARE
  v_fee_percentage NUMERIC := 1.5;
  v_fee_fixed NUMERIC := 0;
BEGIN
  SELECT tf.fee_percentage, tf.fee_fixed
  INTO v_fee_percentage, v_fee_fixed
  FROM public.transfer_fees tf
  WHERE tf.is_active = true
    AND (tf.currency_from = p_currency_from OR tf.currency_from IS NULL)
    AND (tf.currency_to = p_currency_to OR tf.currency_to IS NULL)
    AND (tf.country_from = p_country_from OR tf.country_from IS NULL)
    AND (tf.country_to = p_country_to OR tf.country_to IS NULL)
    AND (tf.min_amount IS NULL OR tf.min_amount <= p_amount)
    AND (tf.max_amount IS NULL OR tf.max_amount >= p_amount)
  ORDER BY 
    CASE WHEN tf.currency_from IS NOT NULL THEN 1 ELSE 2 END,
    CASE WHEN tf.currency_to IS NOT NULL THEN 1 ELSE 2 END
  LIMIT 1;
  
  IF v_fee_percentage IS NULL THEN
    v_fee_percentage := 1.5;
  END IF;
  
  RETURN QUERY SELECT 
    v_fee_percentage,
    ROUND((p_amount * v_fee_percentage / 100) + COALESCE(v_fee_fixed, 0), 2) AS fee_amount,
    ROUND(p_amount - ((p_amount * v_fee_percentage / 100) + COALESCE(v_fee_fixed, 0)), 2) AS amount_after_fee;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 10. Fonction pour obtenir le taux interne (avec marge de sécurité)
CREATE OR REPLACE FUNCTION public.get_internal_rate(
  p_from_currency VARCHAR,
  p_to_currency VARCHAR,
  p_transfer_type VARCHAR DEFAULT 'WALLET_TO_WALLET'
)
RETURNS TABLE(
  rate_public NUMERIC,
  rate_internal NUMERIC,
  security_margin NUMERIC
) AS $$
DECLARE
  v_rate NUMERIC := 1;
  v_margin NUMERIC := 0.005;
BEGIN
  SELECT er.rate, COALESCE(er.security_margin, 0.005)
  INTO v_rate, v_margin
  FROM public.exchange_rates er
  WHERE er.from_currency = p_from_currency
    AND er.to_currency = p_to_currency
    AND er.is_active = true
  LIMIT 1;
  
  IF v_rate IS NULL THEN
    SELECT 1.0 / er.rate, COALESCE(er.security_margin, 0.005)
    INTO v_rate, v_margin
    FROM public.exchange_rates er
    WHERE er.from_currency = p_to_currency
      AND er.to_currency = p_from_currency
      AND er.is_active = true
    LIMIT 1;
  END IF;
  
  IF v_rate IS NULL THEN
    v_rate := 1;
    v_margin := 0.005;
  END IF;
  
  IF p_transfer_type = 'WALLET_TO_WALLET' THEN
    RETURN QUERY SELECT 
      v_rate AS rate_public,
      ROUND(v_rate * (1 + v_margin), 8) AS rate_internal,
      v_margin AS security_margin;
  ELSE
    RETURN QUERY SELECT 
      v_rate AS rate_public,
      v_rate AS rate_internal,
      0::NUMERIC AS security_margin;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 11. Insérer les frais par défaut
INSERT INTO public.transfer_fees (currency_from, currency_to, fee_percentage, fee_fixed)
VALUES 
  (NULL, NULL, 1.5, 0),
  ('GNF', 'GNF', 1.0, 0),
  ('EUR', 'EUR', 0.5, 0),
  ('USD', 'USD', 0.5, 0),
  ('XOF', 'XOF', 1.0, 0)
ON CONFLICT DO NOTHING;

-- 12. Trigger pour updated_at
CREATE OR REPLACE FUNCTION update_wallet_transfers_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

DROP TRIGGER IF EXISTS trigger_wallet_transfers_updated_at ON public.wallet_transfers;
CREATE TRIGGER trigger_wallet_transfers_updated_at
  BEFORE UPDATE ON public.wallet_transfers
  FOR EACH ROW
  EXECUTE FUNCTION update_wallet_transfers_updated_at();