-- Supprimer l'ancienne fonction et recréer avec signature simplifiée
DROP FUNCTION IF EXISTS calculate_system_health();
DROP FUNCTION IF EXISTS auto_cleanup_old_errors();

-- Recréer calculate_system_health sans appeler cleanup (evite erreur read-only)
CREATE OR REPLACE FUNCTION calculate_system_health()
RETURNS TABLE (
  score INT,
  critical_count INT,
  moderate_count INT,
  minor_count INT,
  recent_fixes INT,
  status TEXT
) AS $$
DECLARE
  v_critical INT := 0;
  v_moderate INT := 0;
  v_minor INT := 0;
  v_fixes INT := 0;
  v_score INT := 100;
  v_status TEXT := 'healthy';
BEGIN
  -- Compter uniquement les erreurs NON corrigées des dernières 24h
  SELECT COALESCE(COUNT(*), 0) INTO v_critical
  FROM system_errors 
  WHERE severity = 'critique' 
    AND status = 'detected'
    AND created_at > NOW() - INTERVAL '24 hours';
  
  SELECT COALESCE(COUNT(*), 0) INTO v_moderate
  FROM system_errors 
  WHERE severity = 'modérée' 
    AND status = 'detected'
    AND created_at > NOW() - INTERVAL '24 hours';
  
  SELECT COALESCE(COUNT(*), 0) INTO v_minor
  FROM system_errors 
  WHERE severity = 'mineure' 
    AND status = 'detected'
    AND created_at > NOW() - INTERVAL '24 hours';
  
  -- Corrections récentes (bonus)
  SELECT COALESCE(COUNT(*), 0) INTO v_fixes
  FROM system_errors 
  WHERE status = 'fixed'
    AND fixed_at > NOW() - INTERVAL '24 hours';
  
  -- Calcul du score
  v_score := 100 - (v_critical * 20) - (v_moderate * 5) - (v_minor * 1) + LEAST(v_fixes * 2, 20);
  v_score := GREATEST(0, LEAST(100, v_score));
  
  IF v_score >= 90 THEN v_status := 'healthy';
  ELSIF v_score >= 70 THEN v_status := 'degraded';
  ELSE v_status := 'critical';
  END IF;
  
  RETURN QUERY SELECT v_score, v_critical, v_moderate, v_minor, v_fixes, v_status;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Fonction de cleanup séparée (à appeler manuellement ou par cron)
CREATE OR REPLACE FUNCTION cleanup_old_errors()
RETURNS void AS $$
BEGIN
  DELETE FROM system_errors WHERE status = 'fixed' AND fixed_at < NOW() - INTERVAL '30 days';
  UPDATE system_errors SET status = 'fixed', fix_applied = true, fix_description = 'Auto-archivé', fixed_at = NOW()
  WHERE severity = 'mineure' AND status = 'detected' AND created_at < NOW() - INTERVAL '7 days';
  UPDATE system_errors SET status = 'fixed', fix_applied = true, fix_description = 'Auto-archivé', fixed_at = NOW()
  WHERE severity = 'modérée' AND status = 'detected' AND created_at < NOW() - INTERVAL '14 days';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;