-- Supprimer l'ancienne fonction et la recréer avec la correction
DROP FUNCTION IF EXISTS detect_all_anomalies(TEXT, TEXT);

-- Recréer la fonction avec les préfixes de table pour éviter l'ambiguïté
CREATE OR REPLACE FUNCTION detect_all_anomalies(
  p_domain_filter TEXT DEFAULT NULL,
  p_severity_filter TEXT DEFAULT NULL
)
RETURNS TABLE (
  rule_id TEXT,
  domain_name TEXT,
  status TEXT,
  anomaly_count BIGINT
) 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Retourner les résultats des règles logiques avec préfixes de table pour éviter l'ambiguïté
  RETURN QUERY
  SELECT 
    lr.id::TEXT AS rule_id,
    lr.domain AS domain_name,
    CASE 
      WHEN lr.is_active THEN 'ACTIVE'
      ELSE 'INACTIVE'
    END AS status,
    COALESCE(
      (SELECT COUNT(*) FROM logic_anomalies la WHERE la.rule_id = lr.id AND la.resolved_at IS NULL),
      0
    ) AS anomaly_count
  FROM logic_rules lr
  WHERE 
    (p_domain_filter IS NULL OR lr.domain = p_domain_filter)
    AND (p_severity_filter IS NULL OR lr.severity = p_severity_filter)
  ORDER BY lr.domain, lr.id;
END;
$$;