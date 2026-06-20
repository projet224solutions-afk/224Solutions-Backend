-- ============================================
-- 🔍 TABLE POUR LOGS D'AUDIT DE SÉCURITÉ
-- Stockage de tous les événements de sécurité
-- ============================================

-- Créer la table security_audit_logs si elle n'existe pas
CREATE TABLE IF NOT EXISTS security_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Type d'événement
  event_type TEXT NOT NULL,
  
  -- Utilisateur (peut être NULL pour événements anonymes)
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  
  -- Informations réseau
  ip_address TEXT,
  user_agent TEXT,
  
  -- Ressource concernée (optionnel)
  resource_type TEXT,
  resource_id TEXT,
  
  -- Action effectuée
  action TEXT,
  
  -- Résultat
  success BOOLEAN NOT NULL DEFAULT false,
  
  -- Sévérité (low, medium, high, critical)
  severity TEXT NOT NULL DEFAULT 'low',
  
  -- Détails additionnels en JSON
  details JSONB DEFAULT '{}',
  
  -- Timestamp
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  -- Contraintes
  CONSTRAINT valid_severity CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  CONSTRAINT valid_event_type CHECK (length(event_type) > 0)
);

-- ============================================
-- INDICES POUR PERFORMANCE
-- ============================================

-- Index sur user_id pour recherches par utilisateur
CREATE INDEX IF NOT EXISTS idx_security_audit_logs_user_id 
ON security_audit_logs(user_id);

-- Index sur event_type pour statistiques
CREATE INDEX IF NOT EXISTS idx_security_audit_logs_event_type 
ON security_audit_logs(event_type);

-- Index sur severity pour alertes critiques
CREATE INDEX IF NOT EXISTS idx_security_audit_logs_severity 
ON security_audit_logs(severity);

-- Index sur created_at pour recherches temporelles
CREATE INDEX IF NOT EXISTS idx_security_audit_logs_created_at 
ON security_audit_logs(created_at DESC);

-- Index composé pour recherches fréquentes
CREATE INDEX IF NOT EXISTS idx_security_audit_logs_user_date 
ON security_audit_logs(user_id, created_at DESC);

-- Index pour événements critiques récents
CREATE INDEX IF NOT EXISTS idx_security_audit_logs_critical 
ON security_audit_logs(severity, created_at DESC) 
WHERE severity IN ('high', 'critical');

-- Index GIN pour recherche dans le JSON details
CREATE INDEX IF NOT EXISTS idx_security_audit_logs_details 
ON security_audit_logs USING gin(details);

-- ============================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================

ALTER TABLE security_audit_logs ENABLE ROW LEVEL SECURITY;

-- Politique : Lecture seule pour admins et PDG
CREATE POLICY "security_audit_logs_admin_read"
ON security_audit_logs FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE profiles.id = auth.uid() 
    AND profiles.role IN ('admin', 'pdg')
  )
);

-- Politique : Insertion autorisée pour le système (service_role)
-- Les utilisateurs normaux ne peuvent pas insérer directement
CREATE POLICY "security_audit_logs_system_insert"
ON security_audit_logs FOR INSERT
WITH CHECK (
  -- Seulement via service_role ou fonction sécurisée
  auth.role() = 'service_role'
  OR
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE profiles.id = auth.uid() 
    AND profiles.role IN ('admin', 'pdg')
  )
);

-- Politique : Aucune modification permise (immutable)
CREATE POLICY "security_audit_logs_no_update"
ON security_audit_logs FOR UPDATE
USING (false);

-- Politique : Aucune suppression permise
CREATE POLICY "security_audit_logs_no_delete"
ON security_audit_logs FOR DELETE
USING (false);

-- ============================================
-- FONCTION UTILITAIRE POUR INSERTION SÉCURISÉE
-- ============================================

-- Fonction pour insérer un log d'audit (appellable par tous)
CREATE OR REPLACE FUNCTION log_security_event(
  p_event_type TEXT,
  p_ip_address TEXT DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL,
  p_resource_type TEXT DEFAULT NULL,
  p_resource_id TEXT DEFAULT NULL,
  p_action TEXT DEFAULT NULL,
  p_success BOOLEAN DEFAULT true,
  p_severity TEXT DEFAULT 'low',
  p_details JSONB DEFAULT '{}'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER -- S'exécute avec privilèges de l'owner
SET search_path = public
AS $$
DECLARE
  v_log_id UUID;
BEGIN
  -- Validation de la sévérité
  IF p_severity NOT IN ('low', 'medium', 'high', 'critical') THEN
    RAISE EXCEPTION 'Invalid severity level: %', p_severity;
  END IF;

  -- Insérer le log
  INSERT INTO security_audit_logs (
    event_type,
    user_id,
    ip_address,
    user_agent,
    resource_type,
    resource_id,
    action,
    success,
    severity,
    details
  ) VALUES (
    p_event_type,
    auth.uid(), -- Utilisateur courant ou NULL si anonyme
    p_ip_address,
    p_user_agent,
    p_resource_type,
    p_resource_id,
    p_action,
    p_success,
    p_severity,
    p_details
  )
  RETURNING id INTO v_log_id;

  RETURN v_log_id;
END;
$$;

-- ============================================
-- VUES UTILES POUR MONITORING
-- ============================================

-- Vue : Événements critiques récents (24h)
CREATE OR REPLACE VIEW recent_critical_events AS
SELECT 
  id,
  event_type,
  user_id,
  ip_address,
  action,
  details,
  created_at
FROM security_audit_logs
WHERE 
  severity IN ('high', 'critical')
  AND created_at > NOW() - INTERVAL '24 hours'
ORDER BY created_at DESC;

-- Vue : Statistiques par utilisateur
CREATE OR REPLACE VIEW user_security_stats AS
SELECT 
  user_id,
  COUNT(*) as total_events,
  COUNT(*) FILTER (WHERE success = false) as failed_events,
  COUNT(*) FILTER (WHERE severity = 'critical') as critical_events,
  MAX(created_at) as last_event
FROM security_audit_logs
WHERE user_id IS NOT NULL
GROUP BY user_id;

-- Vue : Statistiques par type d'événement
CREATE OR REPLACE VIEW event_type_stats AS
SELECT 
  event_type,
  COUNT(*) as count,
  COUNT(*) FILTER (WHERE success = false) as failures,
  COUNT(*) FILTER (WHERE severity IN ('high', 'critical')) as serious_events,
  MAX(created_at) as last_occurrence
FROM security_audit_logs
GROUP BY event_type
ORDER BY count DESC;

-- Vue : IPs suspectes (beaucoup d'échecs)
CREATE OR REPLACE VIEW suspicious_ips AS
SELECT 
  ip_address,
  COUNT(*) as total_attempts,
  COUNT(*) FILTER (WHERE success = false) as failed_attempts,
  COUNT(*) FILTER (WHERE event_type LIKE '%injection%') as injection_attempts,
  ARRAY_AGG(DISTINCT event_type) as event_types,
  MAX(created_at) as last_seen
FROM security_audit_logs
WHERE 
  ip_address IS NOT NULL
  AND created_at > NOW() - INTERVAL '7 days'
GROUP BY ip_address
HAVING COUNT(*) FILTER (WHERE success = false) > 10
ORDER BY failed_attempts DESC;

-- ============================================
-- FONCTION DE NETTOYAGE AUTOMATIQUE (OPTIONNEL)
-- ============================================

-- Fonction pour archiver/supprimer les vieux logs (>90 jours)
CREATE OR REPLACE FUNCTION cleanup_old_security_logs()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_deleted_count INTEGER;
BEGIN
  -- Supprimer les logs de plus de 90 jours (sauf critiques)
  DELETE FROM security_audit_logs
  WHERE 
    created_at < NOW() - INTERVAL '90 days'
    AND severity NOT IN ('critical', 'high')
  RETURNING COUNT(*) INTO v_deleted_count;

  -- Logger l'opération de nettoyage
  INSERT INTO security_audit_logs (
    event_type,
    action,
    success,
    severity,
    details
  ) VALUES (
    'system_maintenance',
    'cleanup_old_logs',
    true,
    'low',
    jsonb_build_object('deleted_count', v_deleted_count)
  );

  RETURN v_deleted_count;
END;
$$;

-- ============================================
-- TRIGGER POUR ALERTES TEMPS RÉEL
-- ============================================

-- Fonction trigger pour alertes critiques
CREATE OR REPLACE FUNCTION notify_critical_security_event()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Si événement critique, envoyer notification
  IF NEW.severity = 'critical' THEN
    PERFORM pg_notify(
      'critical_security_event',
      json_build_object(
        'id', NEW.id,
        'event_type', NEW.event_type,
        'user_id', NEW.user_id,
        'details', NEW.details
      )::text
    );
  END IF;
  
  RETURN NEW;
END;
$$;

-- Créer le trigger
DROP TRIGGER IF EXISTS trigger_critical_security_alert ON security_audit_logs;
CREATE TRIGGER trigger_critical_security_alert
AFTER INSERT ON security_audit_logs
FOR EACH ROW
WHEN (NEW.severity = 'critical')
EXECUTE FUNCTION notify_critical_security_event();

-- ============================================
-- PERMISSIONS
-- ============================================

-- Donner accès en lecture aux admins
GRANT SELECT ON security_audit_logs TO authenticated;
GRANT SELECT ON recent_critical_events TO authenticated;
GRANT SELECT ON user_security_stats TO authenticated;
GRANT SELECT ON event_type_stats TO authenticated;
GRANT SELECT ON suspicious_ips TO authenticated;

-- Fonction log_security_event accessible à tous
GRANT EXECUTE ON FUNCTION log_security_event TO authenticated, anon;

-- Fonction de nettoyage réservée aux admins
GRANT EXECUTE ON FUNCTION cleanup_old_security_logs TO service_role;

-- ============================================
-- COMMENTAIRES
-- ============================================

COMMENT ON TABLE security_audit_logs IS 
'Table principale pour l''audit de sécurité. Enregistre tous les événements de sécurité du système. Immuable après insertion.';

COMMENT ON COLUMN security_audit_logs.event_type IS 
'Type d''événement (ex: login_success, unauthorized_access, payment_created)';

COMMENT ON COLUMN security_audit_logs.severity IS 
'Niveau de sévérité : low (info), medium (warning), high (error), critical (alerte immédiate)';

COMMENT ON COLUMN security_audit_logs.details IS 
'Détails additionnels en JSON. Ne doit PAS contenir de données sensibles en clair.';

COMMENT ON FUNCTION log_security_event IS 
'Fonction sécurisée pour insérer un événement d''audit. Utilisable par tous les rôles.';

COMMENT ON VIEW recent_critical_events IS 
'Vue des événements critiques des dernières 24h pour monitoring en temps réel.';

COMMENT ON VIEW suspicious_ips IS 
'Vue des IPs avec comportement suspect (nombreux échecs ou tentatives d''injection).';

-- ============================================
-- EXEMPLES D'UTILISATION
-- ============================================

/*
-- Insérer un log depuis SQL
SELECT log_security_event(
  'login_failed',
  '192.168.1.1',
  'Mozilla/5.0',
  NULL,
  NULL,
  'login_attempt',
  false,
  'medium',
  '{"reason": "invalid_password"}'::jsonb
);

-- Requêtes de monitoring
-- Événements critiques récents
SELECT * FROM recent_critical_events;

-- Top utilisateurs par activité
SELECT * FROM user_security_stats ORDER BY total_events DESC LIMIT 10;

-- IPs suspectes
SELECT * FROM suspicious_ips;

-- Statistiques par type d'événement
SELECT * FROM event_type_stats;

-- Nettoyage des vieux logs (admin seulement)
SELECT cleanup_old_security_logs();
*/
