-- Complete Security Defense System Tables

-- Table: security_incidents
CREATE TABLE IF NOT EXISTS security_incidents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_type TEXT NOT NULL,
  severity TEXT NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'investigating', 'contained', 'resolved', 'closed')),
  title TEXT NOT NULL,
  description TEXT,
  source_ip INET,
  affected_users UUID[],
  indicators JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  detected_at TIMESTAMPTZ DEFAULT NOW(),
  investigated_at TIMESTAMPTZ,
  contained_at TIMESTAMPTZ,
  resolved_at TIMESTAMPTZ,
  assigned_to UUID REFERENCES auth.users(id)
);

-- Table: security_alerts  
CREATE TABLE IF NOT EXISTS security_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_type TEXT NOT NULL,
  severity TEXT NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  incident_id UUID REFERENCES security_incidents(id),
  description TEXT NOT NULL,
  source TEXT,
  acknowledged BOOLEAN DEFAULT FALSE,
  acknowledged_by UUID REFERENCES auth.users(id),
  acknowledged_at TIMESTAMPTZ,
  auto_actions JSONB DEFAULT '[]',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table: blocked_ips
CREATE TABLE IF NOT EXISTS blocked_ips (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ip_address INET NOT NULL UNIQUE,
  reason TEXT NOT NULL,
  incident_id UUID REFERENCES security_incidents(id),
  blocked_at TIMESTAMPTZ DEFAULT NOW(),
  blocked_by UUID REFERENCES auth.users(id),
  expires_at TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT TRUE,
  unblocked_at TIMESTAMPTZ,
  unblocked_by UUID REFERENCES auth.users(id)
);

-- Table: security_snapshots
CREATE TABLE IF NOT EXISTS security_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_type TEXT NOT NULL,
  incident_id UUID REFERENCES security_incidents(id),
  storage_path TEXT NOT NULL,
  snapshot_hash TEXT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table: security_audit_logs
CREATE TABLE IF NOT EXISTS security_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  action TEXT NOT NULL,
  actor_type TEXT NOT NULL,
  actor_id UUID REFERENCES auth.users(id),
  target_type TEXT,
  target_id UUID,
  incident_id UUID REFERENCES security_incidents(id),
  ip_address INET,
  details JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table: forensic_reports
CREATE TABLE IF NOT EXISTS forensic_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id UUID REFERENCES security_incidents(id),
  report_type TEXT NOT NULL,
  report_data JSONB NOT NULL,
  file_path TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  created_by UUID REFERENCES auth.users(id)
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_security_incidents_status ON security_incidents(status);
CREATE INDEX IF NOT EXISTS idx_security_incidents_severity ON security_incidents(severity);
CREATE INDEX IF NOT EXISTS idx_security_alerts_incident ON security_alerts(incident_id);
CREATE INDEX IF NOT EXISTS idx_blocked_ips_active ON blocked_ips(is_active);
CREATE INDEX IF NOT EXISTS idx_security_snapshots_incident ON security_snapshots(incident_id);
CREATE INDEX IF NOT EXISTS idx_security_audit_incident ON security_audit_logs(incident_id);
CREATE INDEX IF NOT EXISTS idx_forensic_reports_incident ON forensic_reports(incident_id);

-- Enable RLS
ALTER TABLE security_incidents ENABLE ROW LEVEL SECURITY;
ALTER TABLE security_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE blocked_ips ENABLE ROW LEVEL SECURITY;
ALTER TABLE security_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE security_audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE forensic_reports ENABLE ROW LEVEL SECURITY;

-- RLS Policies for admins (using admin role only)
CREATE POLICY "Admins can manage security incidents"
ON security_incidents FOR ALL TO authenticated
USING (has_role(auth.uid(), 'admin'::user_role));

CREATE POLICY "Admins can manage security alerts"
ON security_alerts FOR ALL TO authenticated
USING (has_role(auth.uid(), 'admin'::user_role));

CREATE POLICY "Admins can manage blocked IPs"
ON blocked_ips FOR ALL TO authenticated
USING (has_role(auth.uid(), 'admin'::user_role));

CREATE POLICY "Admins can manage security snapshots"
ON security_snapshots FOR ALL TO authenticated
USING (has_role(auth.uid(), 'admin'::user_role));

CREATE POLICY "Admins can manage security audit logs"
ON security_audit_logs FOR ALL TO authenticated
USING (has_role(auth.uid(), 'admin'::user_role));

CREATE POLICY "Admins can manage forensic reports"
ON forensic_reports FOR ALL TO authenticated
USING (has_role(auth.uid(), 'admin'::user_role));