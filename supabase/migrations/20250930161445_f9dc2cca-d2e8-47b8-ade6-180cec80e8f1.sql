-- ÉTAPE 1: Configuration de la base de données PDG

-- 1. Table audit_logs: Journal d'audit immuable pour toutes les actions PDG
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id UUID NOT NULL REFERENCES auth.users(id),
  action VARCHAR(255) NOT NULL,
  target_type VARCHAR(100),
  target_id UUID,
  data_json JSONB,
  ip_address VARCHAR(50),
  user_agent TEXT,
  hash VARCHAR(64),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Index pour recherche rapide
CREATE INDEX idx_audit_logs_actor ON public.audit_logs(actor_id);
CREATE INDEX idx_audit_logs_created ON public.audit_logs(created_at DESC);
CREATE INDEX idx_audit_logs_target ON public.audit_logs(target_type, target_id);

-- 2. Table commission_config: Configuration globale des commissions
CREATE TABLE IF NOT EXISTS public.commission_config (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_name VARCHAR(100) NOT NULL,
  transaction_type VARCHAR(50) NOT NULL,
  commission_type VARCHAR(20) NOT NULL CHECK (commission_type IN ('percentage', 'fixed', 'hybrid')),
  commission_value NUMERIC(10, 4) NOT NULL,
  min_amount NUMERIC(15, 2),
  max_amount NUMERIC(15, 2),
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id),
  UNIQUE(service_name, transaction_type)
);

-- 3. Table wallet_transactions: Transactions wallet détaillées
CREATE TABLE IF NOT EXISTS public.wallet_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id VARCHAR(50) UNIQUE NOT NULL,
  sender_wallet_id UUID,
  receiver_wallet_id UUID,
  amount NUMERIC(15, 2) NOT NULL,
  fee NUMERIC(15, 2) NOT NULL DEFAULT 0,
  net_amount NUMERIC(15, 2) NOT NULL,
  currency VARCHAR(3) NOT NULL DEFAULT 'GNF',
  transaction_type VARCHAR(50) NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'reversed')),
  description TEXT,
  metadata JSONB,
  device_info JSONB,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  completed_at TIMESTAMP WITH TIME ZONE
);

CREATE INDEX idx_wallet_trans_sender ON public.wallet_transactions(sender_wallet_id);
CREATE INDEX idx_wallet_trans_receiver ON public.wallet_transactions(receiver_wallet_id);
CREATE INDEX idx_wallet_trans_status ON public.wallet_transactions(status);
CREATE INDEX idx_wallet_trans_created ON public.wallet_transactions(created_at DESC);

-- 4. Table fraud_detection_logs: Logs de détection de fraude
CREATE TABLE IF NOT EXISTS public.fraud_detection_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id),
  transaction_id UUID,
  risk_score NUMERIC(5, 2) NOT NULL,
  risk_level VARCHAR(20) NOT NULL CHECK (risk_level IN ('low', 'medium', 'high', 'critical')),
  flags JSONB NOT NULL,
  action_taken VARCHAR(50),
  reviewed BOOLEAN NOT NULL DEFAULT false,
  reviewed_by UUID REFERENCES auth.users(id),
  reviewed_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_fraud_user ON public.fraud_detection_logs(user_id);
CREATE INDEX idx_fraud_risk ON public.fraud_detection_logs(risk_level, reviewed);
CREATE INDEX idx_fraud_created ON public.fraud_detection_logs(created_at DESC);

-- 5. Table copilot_conversations: Conversations avec le copilote IA PDG
CREATE TABLE IF NOT EXISTS public.copilot_conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pdg_user_id UUID NOT NULL REFERENCES auth.users(id),
  message_in TEXT NOT NULL,
  message_out TEXT NOT NULL,
  actions JSONB,
  mfa_verified BOOLEAN NOT NULL DEFAULT false,
  executed BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_copilot_user ON public.copilot_conversations(pdg_user_id);
CREATE INDEX idx_copilot_created ON public.copilot_conversations(created_at DESC);

-- Enable RLS sur toutes les tables PDG
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commission_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fraud_detection_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.copilot_conversations ENABLE ROW LEVEL SECURITY;

-- Politiques RLS: Seul le PDG peut accéder aux données
CREATE POLICY "PDG only access audit_logs" ON public.audit_logs
  FOR ALL USING (has_role(auth.uid(), 'admin'));

CREATE POLICY "PDG only access commission_config" ON public.commission_config
  FOR ALL USING (has_role(auth.uid(), 'admin'));

CREATE POLICY "PDG only access wallet_transactions" ON public.wallet_transactions
  FOR ALL USING (has_role(auth.uid(), 'admin'));

CREATE POLICY "PDG only access fraud_logs" ON public.fraud_detection_logs
  FOR ALL USING (has_role(auth.uid(), 'admin'));

CREATE POLICY "PDG only access copilot" ON public.copilot_conversations
  FOR ALL USING (auth.uid() = pdg_user_id AND has_role(auth.uid(), 'admin'));

-- Fonction pour générer un ID de transaction unique
CREATE OR REPLACE FUNCTION public.generate_transaction_id()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  new_id TEXT;
BEGIN
  new_id := 'TXN' || TO_CHAR(NOW(), 'YYYYMMDD') || LPAD(FLOOR(RANDOM() * 1000000)::TEXT, 6, '0');
  
  WHILE EXISTS (SELECT 1 FROM public.wallet_transactions WHERE transaction_id = new_id) LOOP
    new_id := 'TXN' || TO_CHAR(NOW(), 'YYYYMMDD') || LPAD(FLOOR(RANDOM() * 1000000)::TEXT, 6, '0');
  END LOOP;
  
  RETURN new_id;
END;
$$;

-- Fonction pour calculer les commissions
CREATE OR REPLACE FUNCTION public.calculate_commission(
  p_service_name VARCHAR,
  p_transaction_type VARCHAR,
  p_amount NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  config RECORD;
  commission NUMERIC := 0;
BEGIN
  SELECT * INTO config
  FROM public.commission_config
  WHERE service_name = p_service_name
    AND transaction_type = p_transaction_type
    AND is_active = true
  LIMIT 1;
  
  IF NOT FOUND THEN
    RETURN 0;
  END IF;
  
  IF config.commission_type = 'percentage' THEN
    commission := p_amount * (config.commission_value / 100);
  ELSIF config.commission_type = 'fixed' THEN
    commission := config.commission_value;
  ELSIF config.commission_type = 'hybrid' THEN
    commission := GREATEST(
      p_amount * (config.commission_value / 100),
      config.min_amount
    );
  END IF;
  
  IF config.max_amount IS NOT NULL THEN
    commission := LEAST(commission, config.max_amount);
  END IF;
  
  RETURN commission;
END;
$$;

-- Fonction pour détecter les fraudes
CREATE OR REPLACE FUNCTION public.detect_fraud(
  p_user_id UUID,
  p_amount NUMERIC,
  p_transaction_type VARCHAR
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  risk_score NUMERIC := 0;
  risk_level VARCHAR(20) := 'low';
  flags JSONB := '[]'::JSONB;
  recent_trans_count INTEGER;
  total_amount_24h NUMERIC;
BEGIN
  -- Vérifier le nombre de transactions dans les dernières 24h
  SELECT COUNT(*), COALESCE(SUM(amount), 0)
  INTO recent_trans_count, total_amount_24h
  FROM public.wallet_transactions
  WHERE sender_wallet_id IN (SELECT id FROM public.wallets WHERE user_id = p_user_id)
    AND created_at > NOW() - INTERVAL '24 hours'
    AND status = 'completed';
  
  -- Règle 1: Plus de 10 transactions en 24h
  IF recent_trans_count >= 10 THEN
    risk_score := risk_score + 30;
    flags := flags || jsonb_build_object('rule', 'high_frequency', 'value', recent_trans_count);
  END IF;
  
  -- Règle 2: Montant total > 5M GNF en 24h
  IF total_amount_24h >= 5000000 THEN
    risk_score := risk_score + 40;
    flags := flags || jsonb_build_object('rule', 'high_volume_24h', 'value', total_amount_24h);
  END IF;
  
  -- Règle 3: Transaction unique > 2M GNF
  IF p_amount >= 2000000 THEN
    risk_score := risk_score + 25;
    flags := flags || jsonb_build_object('rule', 'large_transaction', 'value', p_amount);
  END IF;
  
  -- Calculer le niveau de risque
  IF risk_score < 30 THEN
    risk_level := 'low';
  ELSIF risk_score < 60 THEN
    risk_level := 'medium';
  ELSIF risk_score < 85 THEN
    risk_level := 'high';
  ELSE
    risk_level := 'critical';
  END IF;
  
  RETURN jsonb_build_object(
    'risk_score', risk_score,
    'risk_level', risk_level,
    'flags', flags
  );
END;
$$;

-- Trigger pour mettre à jour updated_at sur commission_config
CREATE OR REPLACE FUNCTION public.update_commission_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trigger_commission_updated_at
BEFORE UPDATE ON public.commission_config
FOR EACH ROW
EXECUTE FUNCTION public.update_commission_updated_at();