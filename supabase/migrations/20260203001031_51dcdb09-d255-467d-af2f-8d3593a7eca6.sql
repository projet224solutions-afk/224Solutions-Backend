
-- ====================================================================
-- DÉTECTION SYNCHRONISATION PERMISSIONS AGENT
-- ====================================================================

-- Fonction de détection des anomalies de permissions
CREATE OR REPLACE FUNCTION detect_permission_sync_anomalies()
RETURNS TABLE(
  agent_id uuid,
  agent_name text,
  missing_in_legacy text[],
  missing_in_advanced text[],
  severity text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH agent_advanced AS (
    SELECT 
      ap.agent_id,
      array_agg(ap.permission_key ORDER BY ap.permission_key) as advanced_keys
    FROM agent_permissions ap
    WHERE ap.permission_value = true
    GROUP BY ap.agent_id
  ),
  agent_legacy AS (
    SELECT 
      am.id as agent_id,
      am.name,
      COALESCE(
        (SELECT array_agg(elem::text ORDER BY elem::text) 
         FROM jsonb_array_elements_text(am.permissions::jsonb) elem),
        ARRAY[]::text[]
      ) as legacy_keys
    FROM agents_management am
    WHERE am.is_active = true
  )
  SELECT 
    al.agent_id,
    al.name as agent_name,
    COALESCE(
      array(SELECT unnest(aa.advanced_keys) EXCEPT SELECT unnest(al.legacy_keys)),
      ARRAY[]::text[]
    ) as missing_in_legacy,
    COALESCE(
      array(SELECT unnest(al.legacy_keys) EXCEPT SELECT unnest(COALESCE(aa.advanced_keys, ARRAY[]::text[]))),
      ARRAY[]::text[]
    ) as missing_in_advanced,
    CASE 
      WHEN array_length(array(SELECT unnest(aa.advanced_keys) EXCEPT SELECT unnest(al.legacy_keys)), 1) > 3 
      THEN 'critical'
      WHEN array_length(array(SELECT unnest(aa.advanced_keys) EXCEPT SELECT unnest(al.legacy_keys)), 1) > 0 
      THEN 'warning'
      ELSE 'info'
    END as severity
  FROM agent_legacy al
  LEFT JOIN agent_advanced aa ON aa.agent_id = al.agent_id
  WHERE 
    (aa.advanced_keys IS NOT NULL AND array_length(array(SELECT unnest(aa.advanced_keys) EXCEPT SELECT unnest(al.legacy_keys)), 1) > 0)
    OR
    (al.legacy_keys IS NOT NULL AND aa.advanced_keys IS NOT NULL AND array_length(array(SELECT unnest(al.legacy_keys) EXCEPT SELECT unnest(aa.advanced_keys)), 1) > 0);
END;
$$;

-- Fonction d'auto-correction des permissions
CREATE OR REPLACE FUNCTION auto_sync_agent_permissions(p_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_advanced_keys text[];
  v_legacy_keys text[];
  v_merged_keys text[];
  v_result jsonb;
BEGIN
  SELECT array_agg(permission_key ORDER BY permission_key)
  INTO v_advanced_keys
  FROM agent_permissions
  WHERE agent_id = p_agent_id AND permission_value = true;
  
  SELECT COALESCE(
    (SELECT array_agg(elem::text ORDER BY elem::text) 
     FROM jsonb_array_elements_text(permissions::jsonb) elem),
    ARRAY[]::text[]
  )
  INTO v_legacy_keys
  FROM agents_management
  WHERE id = p_agent_id;
  
  v_merged_keys := ARRAY(
    SELECT DISTINCT unnest(
      COALESCE(v_advanced_keys, ARRAY[]::text[]) || 
      COALESCE(v_legacy_keys, ARRAY[]::text[])
    ) ORDER BY 1
  );
  
  UPDATE agents_management
  SET permissions = to_jsonb(v_merged_keys),
      updated_at = now()
  WHERE id = p_agent_id;
  
  INSERT INTO agent_permissions (agent_id, permission_key, permission_value)
  SELECT p_agent_id, key, true
  FROM unnest(v_merged_keys) as key
  ON CONFLICT (agent_id, permission_key) 
  DO UPDATE SET permission_value = true, updated_at = now();
  
  v_result := jsonb_build_object(
    'success', true,
    'agent_id', p_agent_id,
    'before_legacy', v_legacy_keys,
    'before_advanced', v_advanced_keys,
    'after_merged', v_merged_keys,
    'synchronized_at', now()
  );
  
  RETURN v_result;
END;
$$;

-- Fonction de scan global des permissions
CREATE OR REPLACE FUNCTION run_permission_sync_validation(p_triggered_by uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_anomaly_count integer := 0;
  v_rec record;
  v_anomaly_id uuid;
BEGIN
  FOR v_rec IN SELECT * FROM detect_permission_sync_anomalies() LOOP
    INSERT INTO logic_anomalies (
      id,
      rule_id,
      domain,
      entity_type,
      entity_id,
      action_type,
      expected_value,
      actual_value,
      severity,
      status,
      detected_at
    ) VALUES (
      gen_random_uuid(),
      'PERM_001',
      'PERMISSIONS',
      'agent',
      v_rec.agent_id::text,
      'permission_sync',
      jsonb_build_object('synced', true),
      jsonb_build_object(
        'missing_in_legacy', v_rec.missing_in_legacy,
        'missing_in_advanced', v_rec.missing_in_advanced,
        'agent_name', v_rec.agent_name
      ),
      v_rec.severity,
      'pending',
      now()
    )
    RETURNING id INTO v_anomaly_id;
    
    v_anomaly_count := v_anomaly_count + 1;
  END LOOP;
  
  RETURN jsonb_build_object(
    'success', true,
    'anomalies_detected', v_anomaly_count,
    'triggered_by', p_triggered_by,
    'executed_at', now()
  );
END;
$$;

-- Grant permissions
GRANT EXECUTE ON FUNCTION detect_permission_sync_anomalies() TO authenticated;
GRANT EXECUTE ON FUNCTION auto_sync_agent_permissions(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION run_permission_sync_validation(uuid) TO authenticated;
