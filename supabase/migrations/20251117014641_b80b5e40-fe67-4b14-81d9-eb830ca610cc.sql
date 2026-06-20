-- ============================================
-- PHASE 2: RAPPORTS PERSONNALISÉS + API PREMIUM
-- ============================================

-- Table pour les templates de rapports personnalisés
CREATE TABLE IF NOT EXISTS public.custom_report_templates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  report_type TEXT NOT NULL CHECK (report_type IN ('sales', 'inventory', 'finance', 'customers', 'performance', 'custom')),
  data_sources JSONB NOT NULL DEFAULT '[]',
  filters JSONB DEFAULT '{}',
  columns JSONB NOT NULL,
  chart_config JSONB,
  schedule TEXT CHECK (schedule IN ('none', 'daily', 'weekly', 'monthly')),
  is_public BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Table pour les rapports générés
CREATE TABLE IF NOT EXISTS public.generated_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id UUID REFERENCES public.custom_report_templates(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  report_data JSONB NOT NULL,
  file_url TEXT,
  format TEXT CHECK (format IN ('pdf', 'excel', 'csv', 'json')),
  generated_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ
);

-- Table pour les clés API
CREATE TABLE IF NOT EXISTS public.api_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  key_name TEXT NOT NULL,
  api_key TEXT UNIQUE NOT NULL,
  api_secret TEXT,
  plan_tier TEXT NOT NULL,
  rate_limit_per_minute INTEGER NOT NULL DEFAULT 60,
  rate_limit_per_day INTEGER NOT NULL DEFAULT 10000,
  is_active BOOLEAN DEFAULT true,
  last_used_at TIMESTAMPTZ,
  usage_count INTEGER DEFAULT 0,
  allowed_ips JSONB DEFAULT '[]',
  allowed_domains JSONB DEFAULT '[]',
  permissions JSONB DEFAULT '[]',
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Table pour le tracking d'utilisation API
CREATE TABLE IF NOT EXISTS public.api_usage (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  api_key_id UUID REFERENCES public.api_keys(id) ON DELETE CASCADE,
  endpoint TEXT NOT NULL,
  method TEXT NOT NULL,
  status_code INTEGER,
  response_time_ms INTEGER,
  request_size_bytes INTEGER,
  response_size_bytes INTEGER,
  ip_address TEXT,
  user_agent TEXT,
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_custom_report_templates_user_id ON public.custom_report_templates(user_id);
CREATE INDEX IF NOT EXISTS idx_generated_reports_user_id ON public.generated_reports(user_id);
CREATE INDEX IF NOT EXISTS idx_generated_reports_template_id ON public.generated_reports(template_id);
CREATE INDEX IF NOT EXISTS idx_api_keys_user_id ON public.api_keys(user_id);
CREATE INDEX IF NOT EXISTS idx_api_keys_api_key ON public.api_keys(api_key);
CREATE INDEX IF NOT EXISTS idx_api_usage_api_key_id ON public.api_usage(api_key_id);
CREATE INDEX IF NOT EXISTS idx_api_usage_created_at ON public.api_usage(created_at);

-- Fonction pour générer une clé API
CREATE OR REPLACE FUNCTION generate_api_key()
RETURNS TEXT AS $$
BEGIN
  RETURN '224_' || encode(gen_random_bytes(32), 'base64');
END;
$$ LANGUAGE plpgsql;

-- RLS Policies pour custom_report_templates
ALTER TABLE public.custom_report_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own report templates" ON public.custom_report_templates;
CREATE POLICY "Users can view their own report templates"
ON public.custom_report_templates FOR SELECT
TO authenticated
USING (user_id = auth.uid() OR is_public = true);

DROP POLICY IF EXISTS "Users can create their own report templates" ON public.custom_report_templates;
CREATE POLICY "Users can create their own report templates"
ON public.custom_report_templates FOR INSERT
TO authenticated
WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can update their own report templates" ON public.custom_report_templates;
CREATE POLICY "Users can update their own report templates"
ON public.custom_report_templates FOR UPDATE
TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can delete their own report templates" ON public.custom_report_templates;
CREATE POLICY "Users can delete their own report templates"
ON public.custom_report_templates FOR DELETE
TO authenticated
USING (user_id = auth.uid());

-- RLS Policies pour generated_reports
ALTER TABLE public.generated_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own generated reports" ON public.generated_reports;
CREATE POLICY "Users can view their own generated reports"
ON public.generated_reports FOR SELECT
TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can create generated reports" ON public.generated_reports;
CREATE POLICY "Users can create generated reports"
ON public.generated_reports FOR INSERT
TO authenticated
WITH CHECK (user_id = auth.uid());

-- RLS Policies pour api_keys
ALTER TABLE public.api_keys ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own API keys" ON public.api_keys;
CREATE POLICY "Users can view their own API keys"
ON public.api_keys FOR SELECT
TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can create API keys" ON public.api_keys;
CREATE POLICY "Users can create API keys"
ON public.api_keys FOR INSERT
TO authenticated
WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can update their own API keys" ON public.api_keys;
CREATE POLICY "Users can update their own API keys"
ON public.api_keys FOR UPDATE
TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can delete their own API keys" ON public.api_keys;
CREATE POLICY "Users can delete their own API keys"
ON public.api_keys FOR DELETE
TO authenticated
USING (user_id = auth.uid());

-- RLS Policies pour api_usage
ALTER TABLE public.api_usage ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their API usage" ON public.api_usage;
CREATE POLICY "Users can view their API usage"
ON public.api_usage FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.api_keys
    WHERE api_keys.id = api_usage.api_key_id
    AND api_keys.user_id = auth.uid()
  )
);