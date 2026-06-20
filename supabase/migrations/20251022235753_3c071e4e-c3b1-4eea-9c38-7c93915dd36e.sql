-- Créer la table api_connections pour superviser les API externes
CREATE TABLE IF NOT EXISTS public.api_connections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  api_name TEXT NOT NULL,
  api_provider TEXT NOT NULL,
  api_type TEXT NOT NULL, -- 'payment', 'sms', 'email', 'storage', 'other'
  api_key_encrypted TEXT NOT NULL,
  encryption_iv TEXT NOT NULL,
  api_secret_encrypted TEXT,
  base_url TEXT,
  status TEXT NOT NULL DEFAULT 'active', -- 'active', 'suspended', 'expired', 'error'
  tokens_limit INTEGER,
  tokens_used INTEGER DEFAULT 0,
  tokens_remaining INTEGER,
  last_request_at TIMESTAMP WITH TIME ZONE,
  expires_at TIMESTAMP WITH TIME ZONE,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Index pour améliorer les performances
CREATE INDEX idx_api_connections_status ON public.api_connections(status);
CREATE INDEX idx_api_connections_created_by ON public.api_connections(created_by);
CREATE INDEX idx_api_connections_api_type ON public.api_connections(api_type);

-- Créer la table api_usage_logs pour le monitoring
CREATE TABLE IF NOT EXISTS public.api_usage_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  api_connection_id UUID REFERENCES public.api_connections(id) ON DELETE CASCADE,
  endpoint TEXT NOT NULL,
  method TEXT NOT NULL,
  status_code INTEGER,
  response_time_ms INTEGER,
  tokens_consumed INTEGER DEFAULT 1,
  error_message TEXT,
  request_metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Index pour les logs
CREATE INDEX idx_api_usage_logs_connection ON public.api_usage_logs(api_connection_id);
CREATE INDEX idx_api_usage_logs_created_at ON public.api_usage_logs(created_at DESC);

-- Créer la table api_alerts pour les alertes automatiques
CREATE TABLE IF NOT EXISTS public.api_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  api_connection_id UUID REFERENCES public.api_connections(id) ON DELETE CASCADE,
  alert_type TEXT NOT NULL, -- 'quota_exceeded', 'suspicious_activity', 'api_error', 'expiring_soon'
  severity TEXT NOT NULL DEFAULT 'medium', -- 'low', 'medium', 'high', 'critical'
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  is_read BOOLEAN DEFAULT false,
  is_resolved BOOLEAN DEFAULT false,
  resolved_at TIMESTAMP WITH TIME ZONE,
  resolved_by UUID REFERENCES auth.users(id),
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Index pour les alertes
CREATE INDEX idx_api_alerts_connection ON public.api_alerts(api_connection_id);
CREATE INDEX idx_api_alerts_is_read ON public.api_alerts(is_read);
CREATE INDEX idx_api_alerts_severity ON public.api_alerts(severity);

-- Activer RLS sur toutes les tables
ALTER TABLE public.api_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.api_usage_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.api_alerts ENABLE ROW LEVEL SECURITY;

-- Policies pour api_connections (seulement les admins/PDG)
CREATE POLICY "PDG can manage api_connections"
  ON public.api_connections
  FOR ALL
  USING (has_role(auth.uid(), 'admin'::user_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::user_role));

-- Policies pour api_usage_logs (lecture seule pour PDG)
CREATE POLICY "PDG can view api_usage_logs"
  ON public.api_usage_logs
  FOR SELECT
  USING (has_role(auth.uid(), 'admin'::user_role));

CREATE POLICY "Service role can insert api_usage_logs"
  ON public.api_usage_logs
  FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

-- Policies pour api_alerts (PDG peut tout faire)
CREATE POLICY "PDG can manage api_alerts"
  ON public.api_alerts
  FOR ALL
  USING (has_role(auth.uid(), 'admin'::user_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::user_role));

-- Fonction pour mettre à jour automatiquement updated_at
CREATE OR REPLACE FUNCTION update_api_connections_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Trigger pour updated_at
CREATE TRIGGER update_api_connections_timestamp
  BEFORE UPDATE ON public.api_connections
  FOR EACH ROW
  EXECUTE FUNCTION update_api_connections_updated_at();

-- Fonction pour calculer les tokens restants
CREATE OR REPLACE FUNCTION update_tokens_remaining()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.tokens_limit IS NOT NULL THEN
    NEW.tokens_remaining = NEW.tokens_limit - NEW.tokens_used;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Trigger pour calculer automatiquement les tokens restants
CREATE TRIGGER calculate_tokens_remaining
  BEFORE INSERT OR UPDATE ON public.api_connections
  FOR EACH ROW
  EXECUTE FUNCTION update_tokens_remaining();