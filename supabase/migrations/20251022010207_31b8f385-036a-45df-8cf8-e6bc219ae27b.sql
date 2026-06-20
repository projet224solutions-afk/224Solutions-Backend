-- Corriger les fonctions avec search_path (dans le bon ordre)

-- Supprimer le trigger d'abord
DROP TRIGGER IF EXISTS trigger_mark_token_used ON pwa_installations;

-- Puis supprimer et recréer les fonctions
DROP FUNCTION IF EXISTS cleanup_expired_tokens();
CREATE OR REPLACE FUNCTION cleanup_expired_tokens()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  DELETE FROM pwa_tokens
  WHERE expires_at < NOW() - INTERVAL '7 days';
END;
$$;

DROP FUNCTION IF EXISTS has_active_installation(UUID);
CREATE OR REPLACE FUNCTION has_active_installation(bureau_uuid UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  installation_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO installation_count
  FROM pwa_installations
  WHERE bureau_id = bureau_uuid
  AND installed_at > NOW() - INTERVAL '30 days';
  
  RETURN installation_count > 0;
END;
$$;

DROP FUNCTION IF EXISTS mark_token_used();
CREATE OR REPLACE FUNCTION mark_token_used()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  UPDATE pwa_tokens
  SET used = true, used_at = NEW.installed_at
  WHERE token = NEW.token
  AND bureau_id = NEW.bureau_id;
  
  RETURN NEW;
END;
$$;

-- Recréer le trigger
CREATE TRIGGER trigger_mark_token_used
  AFTER INSERT ON pwa_installations
  FOR EACH ROW
  WHEN (NEW.token IS NOT NULL)
  EXECUTE FUNCTION mark_token_used();

-- Supprimer la vue SECURITY DEFINER et la recréer en vue normale
DROP VIEW IF EXISTS bureau_pwa_stats;
CREATE VIEW bureau_pwa_stats AS
SELECT 
  b.id as bureau_id,
  b.prefecture,
  b.commune,
  COUNT(DISTINCT pi.id) as total_installations,
  COUNT(DISTINCT CASE WHEN pi.installed_at > NOW() - INTERVAL '30 days' THEN pi.id END) as recent_installations,
  COUNT(DISTINCT CASE WHEN pi.is_mobile = true THEN pi.id END) as mobile_installations,
  COUNT(DISTINCT CASE WHEN pi.is_mobile = false THEN pi.id END) as desktop_installations,
  MAX(pi.installed_at) as last_installation,
  COUNT(DISTINCT pt.id) as total_tokens_generated,
  COUNT(DISTINCT CASE WHEN pt.used = true THEN pt.id END) as tokens_used,
  COUNT(DISTINCT bal.id) as total_access_attempts
FROM bureaus b
LEFT JOIN pwa_installations pi ON b.id = pi.bureau_id
LEFT JOIN pwa_tokens pt ON b.id = pt.bureau_id
LEFT JOIN bureau_access_logs bal ON b.id = bal.bureau_id
GROUP BY b.id, b.prefecture, b.commune;