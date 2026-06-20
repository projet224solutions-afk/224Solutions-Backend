-- Fix detect_all_anomalies(): align with real schema (logic_rules.enabled, logic_anomalies.rule_id TEXT)

DROP FUNCTION IF EXISTS public.detect_all_anomalies(TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.detect_all_anomalies(
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
  RETURN QUERY
  SELECT
    lr.rule_id AS rule_id,
    lr.domain AS domain_name,
    CASE
      WHEN lr.enabled THEN 'ACTIVE'
      ELSE 'INACTIVE'
    END AS status,
    COALESCE(
      (
        SELECT COUNT(*)
        FROM public.logic_anomalies la
        WHERE la.rule_id = lr.rule_id
          AND la.resolved_at IS NULL
      ),
      0
    ) AS anomaly_count
  FROM public.logic_rules lr
  WHERE (p_domain_filter IS NULL OR lr.domain = p_domain_filter)
    AND (p_severity_filter IS NULL OR lr.severity = p_severity_filter)
  ORDER BY lr.domain, lr.rule_id;
END;
$$;