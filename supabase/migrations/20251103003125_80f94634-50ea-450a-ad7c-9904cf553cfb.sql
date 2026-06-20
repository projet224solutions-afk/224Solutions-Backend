-- Amélioration du système Escrow avec logs et automation (corrigé)

-- Table escrow_logs pour l'audit
CREATE TABLE IF NOT EXISTS public.escrow_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escrow_id UUID NOT NULL REFERENCES public.escrow_transactions(id) ON DELETE CASCADE,
  action TEXT NOT NULL CHECK (action IN ('created', 'requested_release', 'released', 'refunded', 'held', 'auto_released', 'disputed')),
  performed_by UUID REFERENCES auth.users(id),
  note TEXT,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Amélioration de escrow_transactions
ALTER TABLE public.escrow_transactions 
  ADD COLUMN IF NOT EXISTS transaction_id UUID REFERENCES public.enhanced_transactions(id),
  ADD COLUMN IF NOT EXISTS available_to_release_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS released_by UUID REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS auto_release_enabled BOOLEAN DEFAULT true,
  ADD COLUMN IF NOT EXISTS dispute_reason TEXT,
  ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}'::jsonb;

-- Ajouter escrow_id dans enhanced_transactions si la table existe
DO $$ 
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'enhanced_transactions') THEN
    ALTER TABLE public.enhanced_transactions 
      ADD COLUMN IF NOT EXISTS escrow_id UUID REFERENCES public.escrow_transactions(id);
  END IF;
END $$;

-- Index pour performance
CREATE INDEX IF NOT EXISTS idx_escrow_logs_escrow_id ON public.escrow_logs(escrow_id);
CREATE INDEX IF NOT EXISTS idx_escrow_logs_created_at ON public.escrow_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_escrow_transactions_status ON public.escrow_transactions(status);
CREATE INDEX IF NOT EXISTS idx_escrow_transactions_seller ON public.escrow_transactions(receiver_id);
CREATE INDEX IF NOT EXISTS idx_escrow_transactions_auto_release ON public.escrow_transactions(available_to_release_at) WHERE status = 'pending' AND auto_release_enabled = true;

-- Fonction pour logger les actions escrow
CREATE OR REPLACE FUNCTION log_escrow_action(
  p_escrow_id UUID,
  p_action TEXT,
  p_performed_by UUID,
  p_note TEXT DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_log_id UUID;
BEGIN
  INSERT INTO public.escrow_logs (escrow_id, action, performed_by, note, metadata)
  VALUES (p_escrow_id, p_action, p_performed_by, p_note, p_metadata)
  RETURNING id INTO v_log_id;
  
  RETURN v_log_id;
END;
$$;

-- Amélioration de initiate_escrow avec logs et auto-release
CREATE OR REPLACE FUNCTION initiate_escrow(
  p_order_id TEXT,
  p_payer_id UUID,
  p_receiver_id UUID,
  p_amount NUMERIC,
  p_currency TEXT DEFAULT 'GNF',
  p_auto_release_days INTEGER DEFAULT 7,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_escrow_id UUID;
  v_payer_wallet_id UUID;
  v_pdg_wallet_id UUID;
BEGIN
  IF p_payer_id = p_receiver_id THEN
    RAISE EXCEPTION 'Le payeur et le receveur doivent être différents';
  END IF;
  
  SELECT id INTO v_payer_wallet_id 
  FROM public.wallets 
  WHERE user_id = p_payer_id AND currency = p_currency;
  
  IF v_payer_wallet_id IS NULL THEN
    RAISE EXCEPTION 'Wallet du payeur introuvable';
  END IF;
  
  IF (SELECT balance FROM public.wallets WHERE id = v_payer_wallet_id) < p_amount THEN
    RAISE EXCEPTION 'Solde insuffisant';
  END IF;
  
  SELECT setting_value::UUID INTO v_pdg_wallet_id
  FROM public.system_settings
  WHERE setting_key = 'pdg_wallet_id';
  
  INSERT INTO public.escrow_transactions (
    order_id, payer_id, receiver_id, amount, currency, status,
    available_to_release_at, auto_release_enabled, metadata
  )
  VALUES (
    p_order_id, p_payer_id, p_receiver_id, p_amount, p_currency, 'pending',
    now() + (p_auto_release_days || ' days')::INTERVAL,
    true,
    p_metadata
  )
  RETURNING id INTO v_escrow_id;
  
  UPDATE public.wallets
  SET balance = balance - p_amount, updated_at = now()
  WHERE id = v_payer_wallet_id;
  
  IF v_pdg_wallet_id IS NOT NULL THEN
    UPDATE public.wallets
    SET balance = balance + p_amount, updated_at = now()
    WHERE id = v_pdg_wallet_id;
  END IF;
  
  PERFORM log_escrow_action(v_escrow_id, 'created', p_payer_id, 'Escrow initiated', p_metadata);
  
  RETURN v_escrow_id;
END;
$$;

-- Amélioration de release_escrow avec logs et revenus PDG
CREATE OR REPLACE FUNCTION release_escrow(
  p_escrow_id UUID,
  p_commission_percent NUMERIC DEFAULT 0,
  p_released_by UUID DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_escrow RECORD;
  v_commission NUMERIC;
  v_net_amount NUMERIC;
  v_receiver_wallet_id UUID;
  v_pdg_wallet_id UUID;
BEGIN
  SELECT * INTO v_escrow
  FROM public.escrow_transactions
  WHERE id = p_escrow_id AND status = 'pending';
  
  IF v_escrow IS NULL THEN
    RAISE EXCEPTION 'Escrow introuvable ou déjà traité';
  END IF;
  
  v_commission := v_escrow.amount * (p_commission_percent / 100);
  v_net_amount := v_escrow.amount - v_commission;
  
  SELECT id INTO v_receiver_wallet_id
  FROM public.wallets
  WHERE user_id = v_escrow.receiver_id AND currency = v_escrow.currency;
  
  SELECT setting_value::UUID INTO v_pdg_wallet_id
  FROM public.system_settings
  WHERE setting_key = 'pdg_wallet_id';
  
  IF v_receiver_wallet_id IS NULL THEN
    INSERT INTO public.wallets (user_id, balance, currency)
    VALUES (v_escrow.receiver_id, 0, v_escrow.currency)
    RETURNING id INTO v_receiver_wallet_id;
  END IF;
  
  IF v_pdg_wallet_id IS NOT NULL THEN
    UPDATE public.wallets
    SET balance = balance - v_escrow.amount, updated_at = now()
    WHERE id = v_pdg_wallet_id;
  END IF;
  
  UPDATE public.wallets
  SET balance = balance + v_net_amount, updated_at = now()
  WHERE id = v_receiver_wallet_id;
  
  IF v_commission > 0 AND EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'revenus_pdg') THEN
    INSERT INTO public.revenus_pdg (source_type, amount, percentage, metadata)
    VALUES (
      'commission_escrow',
      v_commission,
      p_commission_percent,
      jsonb_build_object('escrow_id', p_escrow_id, 'order_id', v_escrow.order_id)
    );
  END IF;
  
  UPDATE public.escrow_transactions
  SET 
    status = 'released',
    commission_percent = p_commission_percent,
    commission_amount = v_commission,
    released_at = now(),
    released_by = COALESCE(p_released_by, auth.uid()),
    updated_at = now()
  WHERE id = p_escrow_id;
  
  PERFORM log_escrow_action(
    p_escrow_id, 
    'released', 
    COALESCE(p_released_by, auth.uid()),
    format('Released %s %s (commission: %s)', v_net_amount, v_escrow.currency, v_commission)
  );
  
  RETURN TRUE;
END;
$$;

-- Fonction pour auto-release (appelée par cron)
CREATE OR REPLACE FUNCTION auto_release_escrows()
RETURNS TABLE(escrow_id UUID, success BOOLEAN, message TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_escrow RECORD;
  v_commission_percent NUMERIC;
BEGIN
  SELECT COALESCE(
    (SELECT setting_value::NUMERIC FROM public.system_settings WHERE setting_key = 'escrow_commission_percent'),
    2.0
  ) INTO v_commission_percent;
  
  FOR v_escrow IN
    SELECT id
    FROM public.escrow_transactions
    WHERE status = 'pending'
      AND auto_release_enabled = true
      AND available_to_release_at <= now()
    ORDER BY available_to_release_at ASC
    LIMIT 100
  LOOP
    BEGIN
      PERFORM release_escrow(v_escrow.id, v_commission_percent, NULL);
      PERFORM log_escrow_action(v_escrow.id, 'auto_released', NULL, 'Auto-released by system');
      
      escrow_id := v_escrow.id;
      success := true;
      message := 'Auto-released successfully';
      RETURN NEXT;
    EXCEPTION WHEN OTHERS THEN
      escrow_id := v_escrow.id;
      success := false;
      message := SQLERRM;
      RETURN NEXT;
    END;
  END LOOP;
END;
$$;

-- Amélioration de refund_escrow avec logs
CREATE OR REPLACE FUNCTION refund_escrow(
  p_escrow_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_escrow RECORD;
  v_payer_wallet_id UUID;
  v_pdg_wallet_id UUID;
BEGIN
  SELECT * INTO v_escrow
  FROM public.escrow_transactions
  WHERE id = p_escrow_id AND status = 'pending';
  
  IF v_escrow IS NULL THEN
    RAISE EXCEPTION 'Escrow introuvable ou déjà traité';
  END IF;
  
  SELECT id INTO v_payer_wallet_id
  FROM public.wallets
  WHERE user_id = v_escrow.payer_id AND currency = v_escrow.currency;
  
  SELECT setting_value::UUID INTO v_pdg_wallet_id
  FROM public.system_settings
  WHERE setting_key = 'pdg_wallet_id';
  
  IF v_pdg_wallet_id IS NOT NULL THEN
    UPDATE public.wallets
    SET balance = balance - v_escrow.amount, updated_at = now()
    WHERE id = v_pdg_wallet_id;
  END IF;
  
  UPDATE public.wallets
  SET balance = balance + v_escrow.amount, updated_at = now()
  WHERE id = v_payer_wallet_id;
  
  UPDATE public.escrow_transactions
  SET 
    status = 'refunded',
    dispute_reason = p_reason,
    updated_at = now()
  WHERE id = p_escrow_id;
  
  PERFORM log_escrow_action(
    p_escrow_id,
    'refunded',
    auth.uid(),
    COALESCE(p_reason, 'Refunded to payer')
  );
  
  RETURN TRUE;
END;
$$;

-- RLS Policies
ALTER TABLE public.escrow_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their escrow logs" ON public.escrow_logs;
CREATE POLICY "Users can view their escrow logs"
  ON public.escrow_logs FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.escrow_transactions et
      WHERE et.id = escrow_logs.escrow_id
        AND (et.payer_id = auth.uid() OR et.receiver_id = auth.uid())
    )
  );

DROP POLICY IF EXISTS "Admins can view all escrow logs" ON public.escrow_logs;
CREATE POLICY "Admins can view all escrow logs"
  ON public.escrow_logs FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

-- Vue pour dashboard PDG
CREATE OR REPLACE VIEW public.escrow_dashboard AS
SELECT 
  et.id,
  et.order_id,
  et.amount,
  et.currency,
  et.status,
  et.created_at,
  et.available_to_release_at,
  et.commission_percent,
  et.commission_amount,
  payer.email as payer_email,
  payer.first_name || ' ' || payer.last_name as payer_name,
  receiver.email as receiver_email,
  receiver.first_name || ' ' || receiver.last_name as receiver_name,
  (SELECT COUNT(*) FROM public.escrow_logs WHERE escrow_id = et.id) as log_count
FROM public.escrow_transactions et
LEFT JOIN public.profiles payer ON et.payer_id = payer.id
LEFT JOIN public.profiles receiver ON et.receiver_id = receiver.id
ORDER BY et.created_at DESC;