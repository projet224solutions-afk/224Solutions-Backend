-- Recréer la table deployment_logs avec la bonne politique RLS
DROP TABLE IF EXISTS deployment_logs;

CREATE TABLE deployment_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  version VARCHAR(50),
  deployed_at TIMESTAMPTZ DEFAULT NOW(),
  deployed_by TEXT,
  commit_hash VARCHAR(40),
  status VARCHAR(20) DEFAULT 'success',
  notes TEXT,
  metadata JSONB DEFAULT '{}'::jsonb
);

-- Activer RLS
ALTER TABLE deployment_logs ENABLE ROW LEVEL SECURITY;

-- Politique: seuls les admins/CEO peuvent voir les logs de déploiement
CREATE POLICY "CEO can manage deployment logs" ON deployment_logs
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE profiles.id = auth.uid() 
      AND profiles.role = 'ceo'
    )
  );

-- Fonction pour auto-résoudre les erreurs de cache après déploiement
CREATE OR REPLACE FUNCTION auto_resolve_cache_errors()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE system_errors 
  SET status = 'resolved', 
      fix_applied = true, 
      fix_description = 'Auto-résolu après déploiement ' || NEW.version
  WHERE status = 'detected'
  AND error_message LIKE '%Failed to fetch dynamically imported module%'
  AND created_at < NEW.deployed_at;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger pour auto-résoudre après déploiement
DROP TRIGGER IF EXISTS tr_auto_resolve_cache_errors ON deployment_logs;
CREATE TRIGGER tr_auto_resolve_cache_errors
  AFTER INSERT ON deployment_logs
  FOR EACH ROW
  EXECUTE FUNCTION auto_resolve_cache_errors();