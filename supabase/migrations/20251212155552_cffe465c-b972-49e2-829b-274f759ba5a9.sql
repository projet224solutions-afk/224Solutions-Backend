-- 1. Corriger la fonction find_user_by_code (problème de type)
DROP FUNCTION IF EXISTS find_user_by_code(TEXT);

CREATE OR REPLACE FUNCTION find_user_by_code(p_code TEXT)
RETURNS TABLE(
  user_id UUID,
  user_type TEXT,
  display_name TEXT,
  identifier TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prefix TEXT;
  v_code_upper TEXT;
BEGIN
  v_code_upper := UPPER(TRIM(p_code));
  v_prefix := LEFT(v_code_upper, 3);
  
  CASE v_prefix
    WHEN 'CLT' THEN
      RETURN QUERY
      SELECT ui.user_id, 'client'::TEXT, COALESCE(p.full_name, p.email)::TEXT, ui.custom_id::TEXT
      FROM user_ids ui
      JOIN profiles p ON p.id = ui.user_id
      WHERE UPPER(ui.custom_id) = v_code_upper;
      
    WHEN 'VND' THEN
      RETURN QUERY
      SELECT ui.user_id, 'vendeur'::TEXT, COALESCE(v.business_name, p.full_name)::TEXT, ui.custom_id::TEXT
      FROM user_ids ui
      JOIN profiles p ON p.id = ui.user_id
      LEFT JOIN vendors v ON v.user_id = ui.user_id
      WHERE UPPER(ui.custom_id) = v_code_upper;
      
    WHEN 'PDG' THEN
      RETURN QUERY
      SELECT ui.user_id, 'pdg'::TEXT, COALESCE(pm.name, p.full_name)::TEXT, ui.custom_id::TEXT
      FROM user_ids ui
      JOIN profiles p ON p.id = ui.user_id
      LEFT JOIN pdg_management pm ON pm.user_id = ui.user_id
      WHERE UPPER(ui.custom_id) = v_code_upper;
      
    WHEN 'AGT' THEN
      RETURN QUERY
      SELECT am.user_id, 'agent'::TEXT, am.name::TEXT, am.agent_code::TEXT
      FROM agents_management am
      WHERE UPPER(am.agent_code) = v_code_upper
      AND am.is_active = true;
      
    WHEN 'SAG' THEN
      RETURN QUERY
      SELECT am.user_id, 'sous_agent'::TEXT, am.name::TEXT, am.agent_code::TEXT
      FROM agents_management am
      WHERE UPPER(am.agent_code) = v_code_upper
      AND am.parent_agent_id IS NOT NULL
      AND am.is_active = true;
      
    WHEN 'VAG' THEN
      RETURN QUERY
      SELECT va.vendor_id, 'vendor_agent'::TEXT, va.name::TEXT, va.custom_id::TEXT
      FROM vendor_agents va
      WHERE UPPER(va.custom_id) = v_code_upper
      AND va.is_active = true;
      
    WHEN 'BST' THEN
      RETURN QUERY
      SELECT b.id, 'bureau'::TEXT, b.commune::TEXT, b.bureau_code::TEXT
      FROM bureaus b
      WHERE UPPER(b.bureau_code) = v_code_upper;
      
    WHEN 'MBR' THEN
      RETURN QUERY
      SELECT m.id, 'membre'::TEXT, m.name::TEXT, m.custom_id::TEXT
      FROM members m
      WHERE UPPER(m.custom_id) = v_code_upper;
      
    WHEN 'DRV' THEN
      RETURN QUERY
      SELECT ui.user_id, 'livreur'::TEXT, COALESCE(p.full_name, p.email)::TEXT, ui.custom_id::TEXT
      FROM user_ids ui
      JOIN profiles p ON p.id = ui.user_id
      WHERE UPPER(ui.custom_id) = v_code_upper;
      
    ELSE
      RETURN QUERY
      SELECT ui.user_id, p.role::TEXT, COALESCE(p.full_name, p.email)::TEXT, ui.custom_id::TEXT
      FROM user_ids ui
      JOIN profiles p ON p.id = ui.user_id
      WHERE UPPER(ui.custom_id) = v_code_upper
      LIMIT 1;
  END CASE;
  
  RETURN;
END;
$$;

-- 2. Fonction pour migrer les vendor_agents existants
CREATE OR REPLACE FUNCTION migrate_vendor_agents_ids()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agent RECORD;
  v_counter INTEGER := 0;
BEGIN
  FOR v_agent IN 
    SELECT id FROM vendor_agents 
    WHERE custom_id IS NULL 
    ORDER BY created_at
  LOOP
    v_counter := v_counter + 1;
    UPDATE vendor_agents 
    SET custom_id = 'VAG' || LPAD(v_counter::TEXT, 4, '0'),
        agent_code = 'VAG' || LPAD(v_counter::TEXT, 4, '0')
    WHERE id = v_agent.id;
  END LOOP;
  
  -- Mettre à jour le compteur
  UPDATE id_counters SET current_value = v_counter WHERE prefix = 'VAG';
END;
$$;

-- Exécuter la migration
SELECT migrate_vendor_agents_ids();

-- Nettoyer
DROP FUNCTION IF EXISTS migrate_vendor_agents_ids();