-- Migration SQL: Création table security_events
-- À exécuter dans Supabase SQL Editor

CREATE TABLE IF NOT EXISTS security_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type TEXT NOT NULL CHECK (event_type IN (
    'login_failed',
    'account_locked',
    'suspicious_activity',
    'csrf_violation',
    'rate_limit_exceeded',
    'unauthorized_access',
    'sql_injection_attempt',
    'xss_attempt'
  )),
  severity TEXT NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  identifier TEXT, -- email ou phone
  ip_address TEXT,
  user_agent TEXT,
  details JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  resolved BOOLEAN DEFAULT FALSE,
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  notes TEXT
);

-- Index pour performances
CREATE INDEX IF NOT EXISTS idx_security_events_created_at ON security_events(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_security_events_severity ON security_events(severity) WHERE resolved = FALSE;
CREATE INDEX IF NOT EXISTS idx_security_events_type ON security_events(event_type);
CREATE INDEX IF NOT EXISTS idx_security_events_user_id ON security_events(user_id) WHERE user_id IS NOT NULL;

-- RLS Policies
ALTER TABLE security_events ENABLE ROW LEVEL SECURITY;

-- Seuls les admins PDG peuvent voir les événements de sécurité
CREATE POLICY "Admin PDG can view security events"
  ON security_events
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM pdg_profiles
      WHERE id = auth.uid()
    )
  );

-- Seuls les admins PDG peuvent marquer comme résolu
CREATE POLICY "Admin PDG can update security events"
  ON security_events
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM pdg_profiles
      WHERE id = auth.uid()
    )
  );

-- Les Edge Functions peuvent insérer (via service role)
CREATE POLICY "Service role can insert security events"
  ON security_events
  FOR INSERT
  WITH CHECK (true);

-- Vue pour dashboard sécurité
CREATE OR REPLACE VIEW security_dashboard AS
SELECT
  event_type,
  severity,
  COUNT(*) as count,
  MAX(created_at) as last_occurrence,
  COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '1 hour') as last_hour,
  COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '24 hours') as last_day,
  COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '7 days') as last_week
FROM security_events
WHERE resolved = FALSE
GROUP BY event_type, severity
ORDER BY severity DESC, count DESC;

-- Grant permissions sur la vue
GRANT SELECT ON security_dashboard TO authenticated;

COMMENT ON TABLE security_events IS 'Logs de tous les événements de sécurité pour monitoring et audit';
COMMENT ON COLUMN security_events.event_type IS 'Type d''événement de sécurité';
COMMENT ON COLUMN security_events.severity IS 'Niveau de gravité: low, medium, high, critical';
COMMENT ON COLUMN security_events.details IS 'Détails JSON de l''événement';
COMMENT ON COLUMN security_events.resolved IS 'Événement résolu ou non';
