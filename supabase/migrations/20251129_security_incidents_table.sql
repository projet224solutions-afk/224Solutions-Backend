-- ============================================
-- 🚨 TABLE POUR GESTION DES INCIDENTS DE SÉCURITÉ
-- Tracking et résolution des incidents de sécurité
-- ============================================

CREATE TABLE IF NOT EXISTS security_incidents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Événement lié
  event_type TEXT NOT NULL,
  
  -- Sévérité (low, medium, high, critical)
  severity TEXT NOT NULL,
  
  -- Utilisateur impliqué (peut être NULL)
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  
  -- Informations réseau
  ip_address TEXT,
  
  -- Détails de l'incident
  details JSONB DEFAULT '{}',
  
  -- Statut (open, investigating, resolved, false_positive)
  status TEXT NOT NULL DEFAULT 'open',
  
  -- Assigné à (admin qui gère l'incident)
  assigned_to UUID REFERENCES profiles(id) ON DELETE SET NULL,
  
  -- Notes de résolution
  resolution_notes TEXT,
  
  -- Actions prises
  actions_taken JSONB DEFAULT '[]',
  
  -- Timestamps
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  
  -- Contraintes
  CONSTRAINT valid_severity CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  CONSTRAINT valid_status CHECK (status IN ('open', 'investigating', 'resolved', 'false_positive'))
);

-- ============================================
-- INDICES
-- ============================================

CREATE INDEX IF NOT EXISTS idx_security_incidents_status 
ON security_incidents(status);

CREATE INDEX IF NOT EXISTS idx_security_incidents_severity 
ON security_incidents(severity);

CREATE INDEX IF NOT EXISTS idx_security_incidents_user_id 
ON security_incidents(user_id);

CREATE INDEX IF NOT EXISTS idx_security_incidents_assigned_to 
ON security_incidents(assigned_to);

CREATE INDEX IF NOT EXISTS idx_security_incidents_created_at 
ON security_incidents(created_at DESC);

-- Index pour incidents ouverts critiques
CREATE INDEX IF NOT EXISTS idx_security_incidents_open_critical 
ON security_incidents(status, severity, created_at DESC) 
WHERE status IN ('open', 'investigating') AND severity IN ('high', 'critical');

-- ============================================
-- RLS
-- ============================================

ALTER TABLE security_incidents ENABLE ROW LEVEL SECURITY;

-- Lecture pour admins et PDG
CREATE POLICY "security_incidents_admin_read"
ON security_incidents FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE profiles.id = auth.uid() 
    AND profiles.role IN ('admin', 'pdg')
  )
);

-- Mise à jour pour admins
CREATE POLICY "security_incidents_admin_update"
ON security_incidents FOR UPDATE
USING (
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE profiles.id = auth.uid() 
    AND profiles.role IN ('admin', 'pdg')
  )
);

-- Insertion via service_role uniquement
CREATE POLICY "security_incidents_service_insert"
ON security_incidents FOR INSERT
WITH CHECK (auth.role() = 'service_role');

-- ============================================
-- TRIGGER POUR MISE À JOUR AUTOMATIQUE
-- ============================================

CREATE OR REPLACE FUNCTION update_incident_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  
  -- Si le statut passe à resolved, mettre resolved_at
  IF NEW.status = 'resolved' AND OLD.status != 'resolved' THEN
    NEW.resolved_at = NOW();
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_incident_timestamp ON security_incidents;
CREATE TRIGGER trigger_update_incident_timestamp
BEFORE UPDATE ON security_incidents
FOR EACH ROW
EXECUTE FUNCTION update_incident_timestamp();

-- ============================================
-- VUES POUR MONITORING
-- ============================================

-- Vue : Incidents ouverts par sévérité
CREATE OR REPLACE VIEW open_incidents_summary AS
SELECT 
  severity,
  COUNT(*) as count,
  AVG(EXTRACT(EPOCH FROM (NOW() - created_at)) / 3600)::INTEGER as avg_age_hours,
  MAX(created_at) as latest_incident
FROM security_incidents
WHERE status IN ('open', 'investigating')
GROUP BY severity
ORDER BY 
  CASE severity
    WHEN 'critical' THEN 1
    WHEN 'high' THEN 2
    WHEN 'medium' THEN 3
    WHEN 'low' THEN 4
  END;

-- Vue : Incidents par utilisateur
CREATE OR REPLACE VIEW incidents_by_user AS
SELECT 
  user_id,
  COUNT(*) as total_incidents,
  COUNT(*) FILTER (WHERE severity = 'critical') as critical_count,
  COUNT(*) FILTER (WHERE status IN ('open', 'investigating')) as open_count,
  MAX(created_at) as last_incident
FROM security_incidents
WHERE user_id IS NOT NULL
GROUP BY user_id
HAVING COUNT(*) > 1
ORDER BY critical_count DESC, total_incidents DESC;

-- Vue : Performance de résolution
CREATE OR REPLACE VIEW incident_resolution_stats AS
SELECT 
  severity,
  COUNT(*) as total_resolved,
  AVG(EXTRACT(EPOCH FROM (resolved_at - created_at)) / 3600)::INTEGER as avg_resolution_time_hours,
  MIN(EXTRACT(EPOCH FROM (resolved_at - created_at)) / 3600)::INTEGER as min_resolution_time_hours,
  MAX(EXTRACT(EPOCH FROM (resolved_at - created_at)) / 3600)::INTEGER as max_resolution_time_hours
FROM security_incidents
WHERE status = 'resolved' AND resolved_at IS NOT NULL
GROUP BY severity;

-- ============================================
-- FONCTION POUR ASSIGNER UN INCIDENT
-- ============================================

CREATE OR REPLACE FUNCTION assign_incident(
  p_incident_id UUID,
  p_admin_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Vérifier que l'admin existe et a le bon rôle
  IF NOT EXISTS (
    SELECT 1 FROM profiles 
    WHERE id = p_admin_id 
    AND role IN ('admin', 'pdg')
  ) THEN
    RAISE EXCEPTION 'User is not an admin';
  END IF;

  -- Mettre à jour l'incident
  UPDATE security_incidents
  SET 
    assigned_to = p_admin_id,
    status = 'investigating',
    updated_at = NOW()
  WHERE id = p_incident_id;

  RETURN FOUND;
END;
$$;

-- ============================================
-- FONCTION POUR RÉSOUDRE UN INCIDENT
-- ============================================

CREATE OR REPLACE FUNCTION resolve_incident(
  p_incident_id UUID,
  p_resolution_notes TEXT,
  p_actions_taken JSONB DEFAULT '[]'
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Vérifier que l'utilisateur est admin
  IF NOT EXISTS (
    SELECT 1 FROM profiles 
    WHERE id = auth.uid() 
    AND role IN ('admin', 'pdg')
  ) THEN
    RAISE EXCEPTION 'Only admins can resolve incidents';
  END IF;

  -- Mettre à jour l'incident
  UPDATE security_incidents
  SET 
    status = 'resolved',
    resolution_notes = p_resolution_notes,
    actions_taken = p_actions_taken,
    resolved_at = NOW(),
    updated_at = NOW()
  WHERE id = p_incident_id;

  -- Logger la résolution
  INSERT INTO security_audit_logs (
    event_type,
    user_id,
    resource_type,
    resource_id,
    action,
    success,
    severity,
    details
  ) VALUES (
    'incident_resolved',
    auth.uid(),
    'security_incident',
    p_incident_id::TEXT,
    'resolve',
    true,
    'low',
    jsonb_build_object(
      'resolution_notes', p_resolution_notes,
      'actions_taken', p_actions_taken
    )
  );

  RETURN FOUND;
END;
$$;

-- ============================================
-- PERMISSIONS
-- ============================================

GRANT SELECT ON security_incidents TO authenticated;
GRANT SELECT ON open_incidents_summary TO authenticated;
GRANT SELECT ON incidents_by_user TO authenticated;
GRANT SELECT ON incident_resolution_stats TO authenticated;

GRANT EXECUTE ON FUNCTION assign_incident TO authenticated;
GRANT EXECUTE ON FUNCTION resolve_incident TO authenticated;

-- ============================================
-- COMMENTAIRES
-- ============================================

COMMENT ON TABLE security_incidents IS 
'Table de tracking des incidents de sécurité. Permet de gérer, assigner et résoudre les incidents détectés.';

COMMENT ON COLUMN security_incidents.status IS 
'Statut de l''incident : open (nouveau), investigating (en cours), resolved (résolu), false_positive (fausse alerte)';

COMMENT ON FUNCTION assign_incident IS 
'Assigne un incident à un administrateur pour investigation';

COMMENT ON FUNCTION resolve_incident IS 
'Marque un incident comme résolu avec notes et actions prises';

-- ============================================
-- DONNÉES INITIALES (OPTIONNEL)
-- ============================================

-- Exemples de types d'incidents courants
DO $$
BEGIN
  -- Aucune donnée initiale nécessaire
  -- Les incidents seront créés automatiquement par le système
END;
$$;
