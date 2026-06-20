-- Table de configuration du seuil de confiance
CREATE TABLE IF NOT EXISTS public.trust_score_config (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  config_key TEXT UNIQUE NOT NULL,
  config_value NUMERIC NOT NULL,
  description TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Insérer les configurations par défaut
INSERT INTO public.trust_score_config (config_key, config_value, description) VALUES
  ('auto_release_threshold', 70, 'Seuil minimum de score pour déblocage automatique (0-100)'),
  ('weight_djomy_confirmed', 25, 'Poids: confirmation API Djomy'),
  ('weight_user_age', 15, 'Poids: ancienneté utilisateur'),
  ('weight_phone_history', 15, 'Poids: historique téléphone'),
  ('weight_vendor_kyc', 20, 'Poids: statut KYC vendeur'),
  ('weight_transaction_amount', 15, 'Poids: montant transaction'),
  ('weight_no_disputes', 10, 'Poids: absence de litiges'),
  ('max_auto_release_amount', 5000000, 'Montant maximum pour déblocage auto (GNF)')
ON CONFLICT (config_key) DO NOTHING;

-- Table des scores de confiance calculés
CREATE TABLE IF NOT EXISTS public.trust_score_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID REFERENCES public.djomy_transactions(id),
  vendor_id UUID,
  user_id UUID,
  total_score NUMERIC NOT NULL,
  threshold_used NUMERIC NOT NULL,
  auto_released BOOLEAN DEFAULT false,
  score_breakdown JSONB NOT NULL,
  djomy_verification_result JSONB,
  decision TEXT NOT NULL, -- 'AUTO_RELEASE', 'BLOCKED', 'MANUAL_REVIEW'
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Table des notifications admin
CREATE TABLE IF NOT EXISTS public.admin_notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  notification_type TEXT NOT NULL,
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  priority TEXT DEFAULT 'medium', -- 'low', 'medium', 'high', 'critical'
  related_entity_type TEXT,
  related_entity_id UUID,
  metadata JSONB,
  is_read BOOLEAN DEFAULT false,
  read_by UUID,
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Ajouter colonne KYC aux vendors si elle n'existe pas
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'vendors' AND column_name = 'kyc_status') THEN
    ALTER TABLE public.vendors ADD COLUMN kyc_status TEXT DEFAULT 'pending';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'vendors' AND column_name = 'kyc_verified_at') THEN
    ALTER TABLE public.vendors ADD COLUMN kyc_verified_at TIMESTAMPTZ;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'vendors' AND column_name = 'dispute_count') THEN
    ALTER TABLE public.vendors ADD COLUMN dispute_count INTEGER DEFAULT 0;
  END IF;
END $$;

-- Ajouter colonnes pour le suivi des auto-release dans vendor_blocked_funds
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'vendor_blocked_funds' AND column_name = 'trust_score') THEN
    ALTER TABLE public.vendor_blocked_funds ADD COLUMN trust_score NUMERIC;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'vendor_blocked_funds' AND column_name = 'auto_released') THEN
    ALTER TABLE public.vendor_blocked_funds ADD COLUMN auto_released BOOLEAN DEFAULT false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'vendor_blocked_funds' AND column_name = 'release_type') THEN
    ALTER TABLE public.vendor_blocked_funds ADD COLUMN release_type TEXT; -- 'AUTO_RELEASE', 'MANUAL_RELEASE'
  END IF;
END $$;

-- Table historique des téléphones utilisés
CREATE TABLE IF NOT EXISTS public.phone_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_number TEXT NOT NULL,
  user_id UUID,
  first_used_at TIMESTAMPTZ DEFAULT now(),
  last_used_at TIMESTAMPTZ DEFAULT now(),
  usage_count INTEGER DEFAULT 1,
  success_count INTEGER DEFAULT 0,
  failed_count INTEGER DEFAULT 0,
  fraud_reports INTEGER DEFAULT 0,
  is_blacklisted BOOLEAN DEFAULT false,
  UNIQUE(phone_number)
);

-- Index pour performance
CREATE INDEX IF NOT EXISTS idx_trust_score_logs_transaction ON public.trust_score_logs(transaction_id);
CREATE INDEX IF NOT EXISTS idx_trust_score_logs_vendor ON public.trust_score_logs(vendor_id);
CREATE INDEX IF NOT EXISTS idx_admin_notifications_unread ON public.admin_notifications(is_read) WHERE is_read = false;
CREATE INDEX IF NOT EXISTS idx_phone_history_phone ON public.phone_history(phone_number);

-- RLS policies
ALTER TABLE public.trust_score_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trust_score_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.phone_history ENABLE ROW LEVEL SECURITY;

-- Policies pour trust_score_config (lecture pour tous, écriture admin)
CREATE POLICY "Trust config readable by authenticated" ON public.trust_score_config
  FOR SELECT TO authenticated USING (true);

-- Policies pour trust_score_logs
CREATE POLICY "Trust logs viewable by admins" ON public.trust_score_logs
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

-- Policies pour admin_notifications
CREATE POLICY "Admin notifications for admins only" ON public.admin_notifications
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- Policies pour phone_history
CREATE POLICY "Phone history for service role" ON public.phone_history
  FOR ALL USING (true);

-- Fonction pour mettre à jour l'historique téléphone
CREATE OR REPLACE FUNCTION public.update_phone_history(
  p_phone TEXT,
  p_user_id UUID,
  p_success BOOLEAN
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO phone_history (phone_number, user_id, usage_count, success_count, failed_count)
  VALUES (p_phone, p_user_id, 1, CASE WHEN p_success THEN 1 ELSE 0 END, CASE WHEN p_success THEN 0 ELSE 1 END)
  ON CONFLICT (phone_number) DO UPDATE SET
    last_used_at = now(),
    usage_count = phone_history.usage_count + 1,
    success_count = phone_history.success_count + CASE WHEN p_success THEN 1 ELSE 0 END,
    failed_count = phone_history.failed_count + CASE WHEN p_success THEN 0 ELSE 1 END;
END;
$$;

-- Fonction pour créer une notification admin
CREATE OR REPLACE FUNCTION public.create_admin_notification(
  p_type TEXT,
  p_title TEXT,
  p_message TEXT,
  p_priority TEXT DEFAULT 'medium',
  p_entity_type TEXT DEFAULT NULL,
  p_entity_id UUID DEFAULT NULL,
  p_metadata JSONB DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_notification_id UUID;
BEGIN
  INSERT INTO admin_notifications (notification_type, title, message, priority, related_entity_type, related_entity_id, metadata)
  VALUES (p_type, p_title, p_message, p_priority, p_entity_type, p_entity_id, p_metadata)
  RETURNING id INTO v_notification_id;
  
  RETURN v_notification_id;
END;
$$;