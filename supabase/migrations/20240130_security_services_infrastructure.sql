-- Migration: Security Services Infrastructure
-- Description: Tables pour MonitoringService, SecureLogger, AlertingService, HealthCheckService
-- Date: 2024-01-30

-- ============================================================================
-- TABLE: secure_logs
-- Description: Logs centralisés et sécurisés avec masquage données sensibles
-- ============================================================================
CREATE TABLE IF NOT EXISTS secure_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  level TEXT NOT NULL CHECK (level IN ('debug', 'info', 'warn', 'error', 'critical')),
  category TEXT NOT NULL CHECK (category IN ('auth', 'payment', 'security', 'api', 'database', 'emergency', 'performance', 'user_action', 'system', 'other')),
  message TEXT NOT NULL,
  context JSONB,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  session_id TEXT,
  timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  stack TEXT,
  environment TEXT NOT NULL CHECK (environment IN ('development', 'staging', 'production')),
  masked BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_secure_logs_level ON secure_logs(level);
CREATE INDEX idx_secure_logs_category ON secure_logs(category);
CREATE INDEX idx_secure_logs_timestamp ON secure_logs(timestamp DESC);
CREATE INDEX idx_secure_logs_user_id ON secure_logs(user_id);
CREATE INDEX idx_secure_logs_environment ON secure_logs(environment);

-- ============================================================================
-- TABLE: error_logs
-- Description: Logs d'erreurs avec résolution tracking
-- ============================================================================
CREATE TABLE IF NOT EXISTS error_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  level TEXT NOT NULL CHECK (level IN ('info', 'warning', 'error', 'critical')),
  category TEXT NOT NULL,
  message TEXT NOT NULL,
  metadata JSONB,
  resolved BOOLEAN DEFAULT FALSE,
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_error_logs_level ON error_logs(level);
CREATE INDEX idx_error_logs_category ON error_logs(category);
CREATE INDEX idx_error_logs_resolved ON error_logs(resolved);
CREATE INDEX idx_error_logs_created_at ON error_logs(created_at DESC);

-- ============================================================================
-- TABLE: system_health_logs
-- Description: Logs des health checks système
-- ============================================================================
CREATE TABLE IF NOT EXISTS system_health_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  overall_status TEXT NOT NULL CHECK (overall_status IN ('healthy', 'degraded', 'critical', 'unknown')),
  security_status TEXT NOT NULL CHECK (security_status IN ('healthy', 'degraded', 'critical', 'unknown')),
  database_status TEXT NOT NULL CHECK (database_status IN ('healthy', 'degraded', 'critical', 'unknown')),
  api_status TEXT NOT NULL CHECK (api_status IN ('healthy', 'degraded', 'critical', 'unknown')),
  frontend_status TEXT NOT NULL CHECK (frontend_status IN ('healthy', 'degraded', 'critical', 'unknown')),
  critical_errors INTEGER DEFAULT 0,
  pending_errors INTEGER DEFAULT 0,
  uptime BIGINT,
  response_time INTEGER,
  active_users INTEGER,
  timestamp TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_system_health_logs_overall_status ON system_health_logs(overall_status);
CREATE INDEX idx_system_health_logs_timestamp ON system_health_logs(timestamp DESC);

-- ============================================================================
-- TABLE: performance_metrics
-- Description: Métriques de performance API/endpoints
-- ============================================================================
CREATE TABLE IF NOT EXISTS performance_metrics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  endpoint TEXT NOT NULL,
  method TEXT NOT NULL,
  response_time INTEGER NOT NULL,
  status_code INTEGER NOT NULL,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_performance_metrics_endpoint ON performance_metrics(endpoint);
CREATE INDEX idx_performance_metrics_timestamp ON performance_metrics(timestamp DESC);
CREATE INDEX idx_performance_metrics_response_time ON performance_metrics(response_time DESC);

-- ============================================================================
-- TABLE: alerts
-- Description: Alertes système (email, push, SMS)
-- ============================================================================
CREATE TABLE IF NOT EXISTS alerts (
  id UUID PRIMARY KEY,
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  priority TEXT NOT NULL CHECK (priority IN ('low', 'medium', 'high', 'critical')),
  category TEXT NOT NULL,
  metadata JSONB,
  sent BOOLEAN DEFAULT FALSE,
  sent_at TIMESTAMPTZ,
  channels TEXT[] NOT NULL,
  recipient_count INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_alerts_priority ON alerts(priority);
CREATE INDEX idx_alerts_category ON alerts(category);
CREATE INDEX idx_alerts_sent ON alerts(sent);
CREATE INDEX idx_alerts_created_at ON alerts(created_at DESC);

-- ============================================================================
-- TABLE: health_check_reports
-- Description: Rapports complets health checks
-- ============================================================================
CREATE TABLE IF NOT EXISTS health_check_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  overall_status TEXT NOT NULL CHECK (overall_status IN ('healthy', 'degraded', 'critical', 'unknown')),
  checks JSONB NOT NULL,
  uptime BIGINT,
  checks_performed INTEGER,
  checks_passed INTEGER,
  checks_failed INTEGER,
  timestamp TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_health_check_reports_overall_status ON health_check_reports(overall_status);
CREATE INDEX idx_health_check_reports_timestamp ON health_check_reports(timestamp DESC);

-- ============================================================================
-- TABLE: csp_violations
-- Description: Violations Content Security Policy
-- ============================================================================
CREATE TABLE IF NOT EXISTS csp_violations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  document_uri TEXT NOT NULL,
  violated_directive TEXT NOT NULL,
  effective_directive TEXT NOT NULL,
  original_policy TEXT,
  blocked_uri TEXT NOT NULL,
  status_code INTEGER,
  timestamp TIMESTAMPTZ NOT NULL,
  critical BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_csp_violations_violated_directive ON csp_violations(violated_directive);
CREATE INDEX idx_csp_violations_blocked_uri ON csp_violations(blocked_uri);
CREATE INDEX idx_csp_violations_critical ON csp_violations(critical);
CREATE INDEX idx_csp_violations_timestamp ON csp_violations(timestamp DESC);

-- ============================================================================
-- RLS POLICIES
-- ============================================================================

-- secure_logs: Admin et PDG seulement
ALTER TABLE secure_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins et PDG peuvent voir tous les logs"
  ON secure_logs FOR SELECT
  USING (
    auth.uid() IN (
      SELECT id FROM profiles WHERE role IN ('admin', 'pdg', 'super_admin')
    )
  );

-- error_logs: Admin et PDG seulement
ALTER TABLE error_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins et PDG peuvent voir toutes les erreurs"
  ON error_logs FOR SELECT
  USING (
    auth.uid() IN (
      SELECT id FROM profiles WHERE role IN ('admin', 'pdg', 'super_admin')
    )
  );

CREATE POLICY "Admins et PDG peuvent résoudre erreurs"
  ON error_logs FOR UPDATE
  USING (
    auth.uid() IN (
      SELECT id FROM profiles WHERE role IN ('admin', 'pdg', 'super_admin')
    )
  );

-- system_health_logs: Admin et PDG seulement
ALTER TABLE system_health_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins et PDG peuvent voir health logs"
  ON system_health_logs FOR SELECT
  USING (
    auth.uid() IN (
      SELECT id FROM profiles WHERE role IN ('admin', 'pdg', 'super_admin')
    )
  );

-- performance_metrics: Admin et PDG seulement
ALTER TABLE performance_metrics ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins et PDG peuvent voir métriques performance"
  ON performance_metrics FOR SELECT
  USING (
    auth.uid() IN (
      SELECT id FROM profiles WHERE role IN ('admin', 'pdg', 'super_admin')
    )
  );

-- alerts: Admin et PDG seulement
ALTER TABLE alerts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins et PDG peuvent voir alertes"
  ON alerts FOR SELECT
  USING (
    auth.uid() IN (
      SELECT id FROM profiles WHERE role IN ('admin', 'pdg', 'super_admin')
    )
  );

-- health_check_reports: Admin et PDG seulement
ALTER TABLE health_check_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins et PDG peuvent voir health check reports"
  ON health_check_reports FOR SELECT
  USING (
    auth.uid() IN (
      SELECT id FROM profiles WHERE role IN ('admin', 'pdg', 'super_admin')
    )
  );

-- csp_violations: Admin seulement
ALTER TABLE csp_violations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins peuvent voir violations CSP"
  ON csp_violations FOR SELECT
  USING (
    auth.uid() IN (
      SELECT id FROM profiles WHERE role IN ('admin', 'super_admin')
    )
  );

-- ============================================================================
-- FUNCTIONS
-- ============================================================================

-- Fonction: Nettoyer vieux logs (rétention 30 jours)
CREATE OR REPLACE FUNCTION cleanup_old_logs()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Supprimer logs > 30 jours sauf critiques
  DELETE FROM secure_logs
  WHERE created_at < NOW() - INTERVAL '30 days'
  AND level != 'critical';

  -- Supprimer erreurs résolues > 30 jours
  DELETE FROM error_logs
  WHERE created_at < NOW() - INTERVAL '30 days'
  AND resolved = TRUE;

  -- Supprimer health logs > 7 jours
  DELETE FROM system_health_logs
  WHERE created_at < NOW() - INTERVAL '7 days';

  -- Supprimer performance metrics > 7 jours
  DELETE FROM performance_metrics
  WHERE created_at < NOW() - INTERVAL '7 days';

  -- Supprimer health check reports > 7 jours
  DELETE FROM health_check_reports
  WHERE created_at < NOW() - INTERVAL '7 days';

  -- Supprimer CSP violations > 7 jours
  DELETE FROM csp_violations
  WHERE created_at < NOW() - INTERVAL '7 days';
END;
$$;

-- Fonction: Obtenir statistiques sécurité
CREATE OR REPLACE FUNCTION get_security_stats()
RETURNS TABLE (
  critical_errors BIGINT,
  pending_errors BIGINT,
  resolved_errors BIGINT,
  csp_violations BIGINT,
  last_health_check TIMESTAMPTZ,
  overall_status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    (SELECT COUNT(*) FROM error_logs WHERE level = 'critical' AND resolved = FALSE) AS critical_errors,
    (SELECT COUNT(*) FROM error_logs WHERE resolved = FALSE) AS pending_errors,
    (SELECT COUNT(*) FROM error_logs WHERE resolved = TRUE) AS resolved_errors,
    (SELECT COUNT(*) FROM csp_violations WHERE created_at > NOW() - INTERVAL '24 hours') AS csp_violations,
    (SELECT MAX(timestamp) FROM system_health_logs) AS last_health_check,
    (SELECT overall_status FROM system_health_logs ORDER BY timestamp DESC LIMIT 1) AS overall_status;
END;
$$;

-- ============================================================================
-- COMMENTAIRES
-- ============================================================================

COMMENT ON TABLE secure_logs IS 'Logs centralisés et sécurisés avec masquage données sensibles';
COMMENT ON TABLE error_logs IS 'Logs d''erreurs avec tracking résolution';
COMMENT ON TABLE system_health_logs IS 'Logs des health checks système périodiques';
COMMENT ON TABLE performance_metrics IS 'Métriques de performance API/endpoints';
COMMENT ON TABLE alerts IS 'Alertes système (email, push, SMS)';
COMMENT ON TABLE health_check_reports IS 'Rapports complets health checks';
COMMENT ON TABLE csp_violations IS 'Violations Content Security Policy détectées';

-- ============================================================================
-- INITIALISATION
-- ============================================================================

-- Créer première entrée health check
INSERT INTO system_health_logs (
  overall_status,
  security_status,
  database_status,
  api_status,
  frontend_status,
  critical_errors,
  pending_errors,
  uptime,
  response_time,
  active_users,
  timestamp
) VALUES (
  'healthy',
  'healthy',
  'healthy',
  'healthy',
  'healthy',
  0,
  0,
  0,
  0,
  0,
  NOW()
);

-- ============================================================================
-- GRANT PERMISSIONS
-- ============================================================================

-- Service role peut tout faire
GRANT ALL ON secure_logs TO service_role;
GRANT ALL ON error_logs TO service_role;
GRANT ALL ON system_health_logs TO service_role;
GRANT ALL ON performance_metrics TO service_role;
GRANT ALL ON alerts TO service_role;
GRANT ALL ON health_check_reports TO service_role;
GRANT ALL ON csp_violations TO service_role;

-- Authenticated users peuvent insérer logs
GRANT INSERT ON secure_logs TO authenticated;
GRANT INSERT ON error_logs TO authenticated;
GRANT INSERT ON performance_metrics TO authenticated;
GRANT INSERT ON csp_violations TO authenticated;
