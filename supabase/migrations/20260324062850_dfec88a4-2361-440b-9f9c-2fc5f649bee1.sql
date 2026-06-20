
-- ============================================================================
-- MONITORING SYSTEM - Tables pour monitoring temps réel production-grade
-- ============================================================================

-- 1. Table principale des événements monitoring
CREATE TABLE IF NOT EXISTS public.monitoring_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type TEXT NOT NULL,
  source TEXT NOT NULL,
  severity TEXT NOT NULL DEFAULT 'info' CHECK (severity IN ('info', 'low', 'medium', 'high', 'critical')),
  message TEXT NOT NULL,
  metadata JSONB DEFAULT '{}',
  user_id UUID,
  ip_address TEXT,
  response_time_ms INTEGER,
  status_code INTEGER,
  service_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_monitoring_events_type ON public.monitoring_events(event_type);
CREATE INDEX idx_monitoring_events_severity ON public.monitoring_events(severity);
CREATE INDEX idx_monitoring_events_created ON public.monitoring_events(created_at DESC);
CREATE INDEX idx_monitoring_events_service ON public.monitoring_events(service_name);

-- 2. Table alertes monitoring avec déduplication
CREATE TABLE IF NOT EXISTS public.monitoring_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_type TEXT NOT NULL,
  severity TEXT NOT NULL DEFAULT 'medium' CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  source TEXT NOT NULL,
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  metadata JSONB DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'acknowledged', 'resolved', 'suppressed')),
  dedupe_key TEXT,
  occurrence_count INTEGER DEFAULT 1,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  acknowledged_at TIMESTAMPTZ,
  acknowledged_by UUID,
  resolved_at TIMESTAMPTZ,
  resolved_by UUID,
  auto_action_taken TEXT,
  cooldown_until TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_monitoring_alerts_status ON public.monitoring_alerts(status);
CREATE INDEX idx_monitoring_alerts_severity ON public.monitoring_alerts(severity);
CREATE INDEX idx_monitoring_alerts_created ON public.monitoring_alerts(created_at DESC);
CREATE UNIQUE INDEX idx_monitoring_alerts_dedupe ON public.monitoring_alerts(dedupe_key) WHERE status IN ('open', 'acknowledged');

-- 3. Table statut des services
CREATE TABLE IF NOT EXISTS public.monitoring_service_status (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_name TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'unknown' CHECK (status IN ('healthy', 'degraded', 'critical', 'unknown', 'maintenance')),
  last_check_at TIMESTAMPTZ DEFAULT now(),
  last_healthy_at TIMESTAMPTZ,
  response_time_ms INTEGER,
  error_rate NUMERIC(5,2) DEFAULT 0,
  uptime_percent NUMERIC(5,2) DEFAULT 100,
  check_count INTEGER DEFAULT 0,
  fail_count INTEGER DEFAULT 0,
  metadata JSONB DEFAULT '{}',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 4. Table métriques monitoring agrégées
CREATE TABLE IF NOT EXISTS public.monitoring_metrics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  metric_name TEXT NOT NULL,
  metric_value NUMERIC NOT NULL,
  service_name TEXT,
  tags JSONB DEFAULT '{}',
  period_start TIMESTAMPTZ NOT NULL DEFAULT now(),
  period_end TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_monitoring_metrics_name ON public.monitoring_metrics(metric_name);
CREATE INDEX idx_monitoring_metrics_period ON public.monitoring_metrics(period_start DESC);

-- 5. RLS
ALTER TABLE public.monitoring_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.monitoring_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.monitoring_service_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.monitoring_metrics ENABLE ROW LEVEL SECURITY;

-- Lecture pour admin/pdg
CREATE POLICY "admin_pdg_read_monitoring_events" ON public.monitoring_events
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg')));

CREATE POLICY "admin_pdg_read_monitoring_alerts" ON public.monitoring_alerts
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg')));

CREATE POLICY "admin_pdg_update_monitoring_alerts" ON public.monitoring_alerts
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg')));

CREATE POLICY "admin_pdg_read_service_status" ON public.monitoring_service_status
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg')));

CREATE POLICY "admin_pdg_read_metrics" ON public.monitoring_metrics
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg')));

-- Insert pour authenticated (événements frontend) et service_role
CREATE POLICY "authenticated_insert_events" ON public.monitoring_events
  FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "authenticated_insert_metrics" ON public.monitoring_metrics
  FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "authenticated_insert_alerts" ON public.monitoring_alerts
  FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "authenticated_insert_service_status" ON public.monitoring_service_status
  FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "authenticated_update_service_status" ON public.monitoring_service_status
  FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg')));

-- Enable realtime for critical tables
ALTER PUBLICATION supabase_realtime ADD TABLE public.monitoring_alerts;
ALTER PUBLICATION supabase_realtime ADD TABLE public.monitoring_service_status;

-- Insert initial service statuses
INSERT INTO public.monitoring_service_status (service_name, display_name, status) VALUES
  ('auth', 'Authentification', 'unknown'),
  ('database', 'Base de données', 'unknown'),
  ('payments', 'Paiements', 'unknown'),
  ('wallet', 'Wallet', 'unknown'),
  ('marketplace', 'Marketplace', 'unknown'),
  ('orders', 'Commandes', 'unknown'),
  ('delivery', 'Livraison', 'unknown'),
  ('taxi', 'Taxi / Tracking', 'unknown'),
  ('services', 'Services de proximité', 'unknown'),
  ('notifications', 'Notifications', 'unknown'),
  ('edge_functions', 'Edge Functions', 'unknown'),
  ('realtime', 'Realtime', 'unknown'),
  ('security', 'Sécurité', 'unknown'),
  ('pwa', 'PWA / Mobile', 'unknown'),
  ('storage', 'Stockage', 'unknown')
ON CONFLICT (service_name) DO NOTHING;

-- Auto-cleanup old events (> 30 days)
CREATE OR REPLACE FUNCTION cleanup_old_monitoring_data()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  DELETE FROM monitoring_events WHERE created_at < now() - interval '30 days';
  DELETE FROM monitoring_metrics WHERE created_at < now() - interval '90 days';
  DELETE FROM monitoring_alerts WHERE status = 'resolved' AND resolved_at < now() - interval '30 days';
END;
$$;
