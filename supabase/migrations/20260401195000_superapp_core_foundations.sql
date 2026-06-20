-- 224SOLUTIONS Super App foundations
-- Additive migration: Identity Core modules + Intelligence/Supervision feature registry

CREATE TABLE IF NOT EXISTS public.identity_user_modules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  module_key TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'pending', 'suspended')),
  source TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'system', 'migration', 'admin')),
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  activated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deactivated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_identity_user_module UNIQUE (user_id, module_key)
);

CREATE INDEX IF NOT EXISTS idx_identity_user_modules_user_id ON public.identity_user_modules(user_id);
CREATE INDEX IF NOT EXISTS idx_identity_user_modules_status ON public.identity_user_modules(status);

CREATE TABLE IF NOT EXISTS public.core_feature_registry (
  feature_key TEXT PRIMARY KEY,
  core_engine TEXT NOT NULL CHECK (core_engine IN ('identity', 'payment', 'commerce', 'intelligence_supervision')),
  owner_module TEXT,
  criticality TEXT NOT NULL DEFAULT 'medium' CHECK (criticality IN ('low', 'medium', 'high', 'critical')),
  auto_monitor BOOLEAN NOT NULL DEFAULT true,
  enabled BOOLEAN NOT NULL DEFAULT true,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.core_feature_health_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  feature_key TEXT NOT NULL REFERENCES public.core_feature_registry(feature_key) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('success', 'degraded', 'failure')),
  signal_type TEXT NOT NULL DEFAULT 'runtime',
  source TEXT NOT NULL DEFAULT 'backend',
  country_code TEXT,
  region TEXT,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  correlation_id TEXT,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_core_feature_health_feature_time ON public.core_feature_health_events(feature_key, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_core_feature_health_status_time ON public.core_feature_health_events(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_core_feature_health_country_time ON public.core_feature_health_events(country_code, created_at DESC);

ALTER TABLE public.identity_user_modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.core_feature_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.core_feature_health_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "identity_user_modules_select_own" ON public.identity_user_modules;
CREATE POLICY "identity_user_modules_select_own"
ON public.identity_user_modules
FOR SELECT
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "identity_user_modules_modify_own" ON public.identity_user_modules;
CREATE POLICY "identity_user_modules_modify_own"
ON public.identity_user_modules
FOR INSERT
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "identity_user_modules_update_own" ON public.identity_user_modules;
CREATE POLICY "identity_user_modules_update_own"
ON public.identity_user_modules
FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "core_feature_registry_admin_read" ON public.core_feature_registry;
CREATE POLICY "core_feature_registry_admin_read"
ON public.core_feature_registry
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.role IN ('pdg', 'admin', 'ceo')
  )
);

DROP POLICY IF EXISTS "core_feature_health_events_admin_read" ON public.core_feature_health_events;
CREATE POLICY "core_feature_health_events_admin_read"
ON public.core_feature_health_events
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.role IN ('pdg', 'admin', 'ceo')
  )
);

DROP POLICY IF EXISTS "service_role_full_core_feature_registry" ON public.core_feature_registry;
CREATE POLICY "service_role_full_core_feature_registry"
ON public.core_feature_registry
FOR ALL
USING (auth.jwt()->>'role' = 'service_role')
WITH CHECK (auth.jwt()->>'role' = 'service_role');

DROP POLICY IF EXISTS "service_role_full_core_feature_health_events" ON public.core_feature_health_events;
CREATE POLICY "service_role_full_core_feature_health_events"
ON public.core_feature_health_events
FOR ALL
USING (auth.jwt()->>'role' = 'service_role')
WITH CHECK (auth.jwt()->>'role' = 'service_role');

DROP POLICY IF EXISTS "service_role_full_identity_user_modules" ON public.identity_user_modules;
CREATE POLICY "service_role_full_identity_user_modules"
ON public.identity_user_modules
FOR ALL
USING (auth.jwt()->>'role' = 'service_role')
WITH CHECK (auth.jwt()->>'role' = 'service_role');

INSERT INTO public.core_feature_registry (feature_key, core_engine, owner_module, criticality, auto_monitor, enabled, metadata)
VALUES
  ('auth.login', 'identity', 'auth', 'critical', true, true, '{"description":"Authentification utilisateur"}'::jsonb),
  ('wallet.transfer', 'payment', 'wallet', 'critical', true, true, '{"description":"Transfert wallet P2P"}'::jsonb),
  ('payment.links.process', 'payment', 'payment_links', 'critical', true, true, '{"description":"Traitement des liens de paiement"}'::jsonb),
  ('marketplace.ranking', 'commerce', 'marketplace_visibility', 'high', true, true, '{"description":"Classement marketplace"}'::jsonb),
  ('surveillance.detect_anomalies', 'intelligence_supervision', 'surveillance', 'high', true, true, '{"description":"Détection d anomalies fonctionnelles"}'::jsonb)
ON CONFLICT (feature_key) DO NOTHING;
