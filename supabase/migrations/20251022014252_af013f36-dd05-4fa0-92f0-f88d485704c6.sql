-- ==========================================
-- MISE À JOUR COMPLÈTE MODULE WALLET
-- Sans supprimer les fonctionnalités existantes
-- ==========================================

-- 1. Ajouter public_id aux wallets existants
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS public_id VARCHAR(8) UNIQUE;
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS wallet_status VARCHAR(20) DEFAULT 'active';
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS is_blocked BOOLEAN DEFAULT false;
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS blocked_reason TEXT;
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS blocked_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS pin_hash TEXT;
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS two_factor_enabled BOOLEAN DEFAULT false;
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS last_transaction_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS total_received NUMERIC DEFAULT 0;
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS total_sent NUMERIC DEFAULT 0;
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS daily_limit NUMERIC DEFAULT 1000000;
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS monthly_limit NUMERIC DEFAULT 10000000;

-- Index pour public_id
CREATE UNIQUE INDEX IF NOT EXISTS idx_wallet_public_id ON public.wallets(public_id) WHERE public_id IS NOT NULL;

-- 2. Table pour les méthodes de recharge/retrait
CREATE TABLE IF NOT EXISTS public.wallet_payment_methods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id UUID NOT NULL REFERENCES public.wallets(id) ON DELETE CASCADE,
  method_type VARCHAR(50) NOT NULL, -- 'bank_card', 'mobile_money', 'wallet_224', 'cash'
  provider VARCHAR(50), -- 'Orange Money', 'MTN', 'Moov', etc.
  account_number TEXT,
  is_default BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wallet_payment_methods_wallet ON public.wallet_payment_methods(wallet_id);

-- 3. Table pour les devises
CREATE TABLE IF NOT EXISTS public.currencies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code VARCHAR(3) NOT NULL UNIQUE, -- USD, EUR, GNF
  name TEXT NOT NULL,
  symbol VARCHAR(10) NOT NULL,
  is_active BOOLEAN DEFAULT true,
  decimal_places INTEGER DEFAULT 2,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Ajouter devises de base
INSERT INTO public.currencies (code, name, symbol, decimal_places)
VALUES 
  ('GNF', 'Franc Guinéen', 'GNF', 0),
  ('USD', 'Dollar Américain', '$', 2),
  ('EUR', 'Euro', '€', 2),
  ('XOF', 'Franc CFA', 'FCFA', 0)
ON CONFLICT (code) DO NOTHING;

-- 4. Table pour les taux de change
CREATE TABLE IF NOT EXISTS public.exchange_rates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  from_currency VARCHAR(3) NOT NULL REFERENCES public.currencies(code),
  to_currency VARCHAR(3) NOT NULL REFERENCES public.currencies(code),
  rate NUMERIC NOT NULL,
  set_by UUID REFERENCES auth.users(id),
  valid_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  valid_until TIMESTAMP WITH TIME ZONE,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(from_currency, to_currency, valid_from)
);

CREATE INDEX IF NOT EXISTS idx_exchange_rates_active ON public.exchange_rates(from_currency, to_currency, is_active);

-- 5. Table pour les commissions et taxes
CREATE TABLE IF NOT EXISTS public.wallet_fees (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_type VARCHAR(50) NOT NULL, -- 'transfer', 'deposit', 'withdraw'
  fee_type VARCHAR(20) NOT NULL, -- 'fixed', 'percentage'
  fee_value NUMERIC NOT NULL,
  min_amount NUMERIC DEFAULT 0,
  max_amount NUMERIC,
  currency VARCHAR(3) DEFAULT 'GNF',
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Frais par défaut
INSERT INTO public.wallet_fees (transaction_type, fee_type, fee_value, currency)
VALUES 
  ('transfer', 'percentage', 1.0, 'GNF'),
  ('deposit', 'percentage', 0.5, 'GNF'),
  ('withdraw', 'percentage', 1.5, 'GNF')
ON CONFLICT DO NOTHING;

-- 6. Table des logs wallet (EXTENSION de l'existant)
CREATE TABLE IF NOT EXISTS public.wallet_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id UUID REFERENCES public.wallets(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id),
  action VARCHAR(50) NOT NULL, -- 'deposit', 'withdraw', 'transfer', 'block', 'unblock'
  amount NUMERIC,
  currency VARCHAR(3) DEFAULT 'GNF',
  balance_before NUMERIC,
  balance_after NUMERIC,
  transaction_id UUID,
  payment_method VARCHAR(50),
  status VARCHAR(20),
  ip_address TEXT,
  user_agent TEXT,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wallet_logs_wallet ON public.wallet_logs(wallet_id);
CREATE INDEX IF NOT EXISTS idx_wallet_logs_user ON public.wallet_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_wallet_logs_action ON public.wallet_logs(action);
CREATE INDEX IF NOT EXISTS idx_wallet_logs_created ON public.wallet_logs(created_at DESC);

-- 7. Table pour détection d'activités suspectes
CREATE TABLE IF NOT EXISTS public.wallet_suspicious_activities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id UUID REFERENCES public.wallets(id),
  user_id UUID REFERENCES auth.users(id),
  activity_type VARCHAR(50) NOT NULL, -- 'high_amount', 'multiple_attempts', 'unusual_pattern'
  severity VARCHAR(20) NOT NULL, -- 'low', 'medium', 'high', 'critical'
  description TEXT,
  detected_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  resolved_at TIMESTAMP WITH TIME ZONE,
  resolved_by UUID REFERENCES auth.users(id),
  action_taken TEXT,
  metadata JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_wallet_suspicious_wallet ON public.wallet_suspicious_activities(wallet_id);
CREATE INDEX IF NOT EXISTS idx_wallet_suspicious_severity ON public.wallet_suspicious_activities(severity);

-- 8. Vue pour statistiques wallet PDG/Admin
CREATE OR REPLACE VIEW public.wallet_admin_stats AS
SELECT 
  COUNT(DISTINCT w.id) as total_wallets,
  COUNT(DISTINCT CASE WHEN w.is_blocked = false THEN w.id END) as active_wallets,
  COUNT(DISTINCT CASE WHEN w.is_blocked = true THEN w.id END) as blocked_wallets,
  SUM(w.balance) as total_balance,
  AVG(w.balance) as average_balance,
  SUM(w.total_received) as total_received_all,
  SUM(w.total_sent) as total_sent_all,
  COUNT(DISTINCT wl.id) as total_transactions_today,
  SUM(CASE WHEN wl.created_at >= NOW() - INTERVAL '24 hours' THEN wl.amount ELSE 0 END) as volume_24h
FROM public.wallets w
LEFT JOIN public.wallet_logs wl ON w.id = wl.wallet_id;

-- 9. Fonction pour convertir devise
CREATE OR REPLACE FUNCTION convert_currency(
  p_amount NUMERIC,
  p_from_currency VARCHAR(3),
  p_to_currency VARCHAR(3)
) RETURNS NUMERIC AS $$
DECLARE
  v_rate NUMERIC;
BEGIN
  IF p_from_currency = p_to_currency THEN
    RETURN p_amount;
  END IF;

  SELECT rate INTO v_rate
  FROM public.exchange_rates
  WHERE from_currency = p_from_currency
    AND to_currency = p_to_currency
    AND is_active = true
    AND valid_from <= NOW()
    AND (valid_until IS NULL OR valid_until > NOW())
  ORDER BY valid_from DESC
  LIMIT 1;

  IF v_rate IS NULL THEN
    RAISE EXCEPTION 'Taux de change non trouvé pour % vers %', p_from_currency, p_to_currency;
  END IF;

  RETURN p_amount * v_rate;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;