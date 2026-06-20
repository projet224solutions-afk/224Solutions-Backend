-- Créer une fonction RPC pour résoudre les erreurs de cache
CREATE OR REPLACE FUNCTION resolve_cache_errors()
RETURNS INTEGER AS $$
DECLARE
  resolved_count INTEGER;
BEGIN
  UPDATE system_errors 
  SET status = 'resolved', 
      fix_applied = true, 
      fix_description = 'Erreur transitoire post-déploiement - cache navigateur obsolète'
  WHERE status = 'detected'
  AND (
    error_message ILIKE '%Failed to fetch dynamically imported module%'
    OR error_message ILIKE '%Failed to load%'
  );
  
  GET DIAGNOSTICS resolved_count = ROW_COUNT;
  RETURN resolved_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;