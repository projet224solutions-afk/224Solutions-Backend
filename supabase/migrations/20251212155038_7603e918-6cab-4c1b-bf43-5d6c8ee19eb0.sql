-- =====================================================
-- ARCHITECTURE PROFESSIONNELLE DES IDs SÉQUENTIELS
-- Pour tous les types d'agents et entités
-- =====================================================

-- 1. Supprimer l'ancienne fonction find_user_by_code
DROP FUNCTION IF EXISTS find_user_by_code(TEXT);

-- 2. Ajouter les préfixes manquants dans id_counters
INSERT INTO id_counters (prefix, current_value)
VALUES 
  ('SAG', 0),  -- Sous-Agents PDG
  ('VAG', 0),  -- Vendor Agents
  ('MBR', 0)   -- Membres Bureau Syndicat
ON CONFLICT (prefix) DO NOTHING;

-- 3. Ajouter colonne custom_id aux tables qui n'en ont pas
ALTER TABLE vendor_agents ADD COLUMN IF NOT EXISTS custom_id VARCHAR(10) UNIQUE;
ALTER TABLE members ADD COLUMN IF NOT EXISTS custom_id VARCHAR(10) UNIQUE;
ALTER TABLE syndicate_workers ADD COLUMN IF NOT EXISTS custom_id VARCHAR(10) UNIQUE;

-- 4. Fonction générique pour générer des IDs séquentiels
CREATE OR REPLACE FUNCTION generate_sequential_id(p_prefix TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_next_value INTEGER;
  v_custom_id TEXT;
BEGIN
  -- Incrémenter et récupérer la nouvelle valeur
  UPDATE id_counters 
  SET current_value = current_value + 1
  WHERE prefix = p_prefix
  RETURNING current_value INTO v_next_value;
  
  -- Si le préfixe n'existe pas, le créer
  IF v_next_value IS NULL THEN
    INSERT INTO id_counters (prefix, current_value)
    VALUES (p_prefix, 1)
    ON CONFLICT (prefix) DO UPDATE SET current_value = id_counters.current_value + 1
    RETURNING current_value INTO v_next_value;
  END IF;
  
  -- Formater l'ID avec padding de 4 chiffres
  v_custom_id := p_prefix || LPAD(v_next_value::TEXT, 4, '0');
  
  RETURN v_custom_id;
END;
$$;

-- 5. Trigger pour vendor_agents (VAG)
CREATE OR REPLACE FUNCTION auto_generate_vendor_agent_id()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Générer custom_id si absent
  IF NEW.custom_id IS NULL THEN
    NEW.custom_id := generate_sequential_id('VAG');
  END IF;
  
  -- Générer agent_code si absent
  IF NEW.agent_code IS NULL OR NEW.agent_code = '' THEN
    NEW.agent_code := NEW.custom_id;
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_auto_generate_vendor_agent_id ON vendor_agents;
CREATE TRIGGER trigger_auto_generate_vendor_agent_id
  BEFORE INSERT ON vendor_agents
  FOR EACH ROW
  EXECUTE FUNCTION auto_generate_vendor_agent_id();

-- 6. Trigger pour members (MBR)
CREATE OR REPLACE FUNCTION auto_generate_member_id()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.custom_id IS NULL THEN
    NEW.custom_id := generate_sequential_id('MBR');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_auto_generate_member_id ON members;
CREATE TRIGGER trigger_auto_generate_member_id
  BEFORE INSERT ON members
  FOR EACH ROW
  EXECUTE FUNCTION auto_generate_member_id();

-- 7. Trigger pour syndicate_workers
CREATE OR REPLACE FUNCTION auto_generate_syndicate_worker_id()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.custom_id IS NULL THEN
    NEW.custom_id := generate_sequential_id('MBR');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_auto_generate_syndicate_worker_id ON syndicate_workers;
CREATE TRIGGER trigger_auto_generate_syndicate_worker_id
  BEFORE INSERT ON syndicate_workers
  FOR EACH ROW
  EXECUTE FUNCTION auto_generate_syndicate_worker_id();

-- 8. Améliorer le trigger pour agents_management (AGT pour agents, SAG pour sous-agents)
CREATE OR REPLACE FUNCTION auto_generate_agent_management_id()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prefix TEXT;
BEGIN
  -- Déterminer le préfixe basé sur le type
  IF NEW.parent_agent_id IS NOT NULL THEN
    v_prefix := 'SAG';  -- Sous-agent
  ELSE
    v_prefix := 'AGT';  -- Agent principal
  END IF;
  
  -- Générer agent_code si absent
  IF NEW.agent_code IS NULL OR NEW.agent_code = '' THEN
    NEW.agent_code := generate_sequential_id(v_prefix);
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_auto_generate_agent_management_id ON agents_management;
CREATE TRIGGER trigger_auto_generate_agent_management_id
  BEFORE INSERT ON agents_management
  FOR EACH ROW
  EXECUTE FUNCTION auto_generate_agent_management_id();

-- 9. Nouvelle fonction find_user_by_code avec tous les préfixes
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
  
  -- Recherche par préfixe
  CASE v_prefix
    WHEN 'CLT' THEN
      RETURN QUERY
      SELECT ui.user_id, 'client'::TEXT, COALESCE(p.full_name, p.email), ui.custom_id
      FROM user_ids ui
      JOIN profiles p ON p.id = ui.user_id
      WHERE UPPER(ui.custom_id) = v_code_upper;
      
    WHEN 'VND' THEN
      RETURN QUERY
      SELECT ui.user_id, 'vendeur'::TEXT, COALESCE(v.business_name, p.full_name), ui.custom_id
      FROM user_ids ui
      JOIN profiles p ON p.id = ui.user_id
      LEFT JOIN vendors v ON v.user_id = ui.user_id
      WHERE UPPER(ui.custom_id) = v_code_upper;
      
    WHEN 'PDG' THEN
      RETURN QUERY
      SELECT ui.user_id, 'pdg'::TEXT, COALESCE(pm.name, p.full_name), ui.custom_id
      FROM user_ids ui
      JOIN profiles p ON p.id = ui.user_id
      LEFT JOIN pdg_management pm ON pm.user_id = ui.user_id
      WHERE UPPER(ui.custom_id) = v_code_upper;
      
    WHEN 'AGT' THEN
      RETURN QUERY
      SELECT am.user_id, 'agent'::TEXT, am.name, am.agent_code
      FROM agents_management am
      WHERE UPPER(am.agent_code) = v_code_upper
      AND am.is_active = true;
      
    WHEN 'SAG' THEN
      RETURN QUERY
      SELECT am.user_id, 'sous_agent'::TEXT, am.name, am.agent_code
      FROM agents_management am
      WHERE UPPER(am.agent_code) = v_code_upper
      AND am.parent_agent_id IS NOT NULL
      AND am.is_active = true;
      
    WHEN 'VAG' THEN
      RETURN QUERY
      SELECT va.vendor_id, 'vendor_agent'::TEXT, va.name::TEXT, va.custom_id
      FROM vendor_agents va
      WHERE UPPER(va.custom_id) = v_code_upper
      AND va.is_active = true;
      
    WHEN 'BST' THEN
      RETURN QUERY
      SELECT b.id, 'bureau'::TEXT, b.commune::TEXT, b.bureau_code
      FROM bureaus b
      WHERE UPPER(b.bureau_code) = v_code_upper;
      
    WHEN 'MBR' THEN
      RETURN QUERY
      SELECT m.id, 'membre'::TEXT, m.name, m.custom_id
      FROM members m
      WHERE UPPER(m.custom_id) = v_code_upper;
      
    WHEN 'DRV' THEN
      RETURN QUERY
      SELECT ui.user_id, 'livreur'::TEXT, COALESCE(p.full_name, p.email), ui.custom_id
      FROM user_ids ui
      JOIN profiles p ON p.id = ui.user_id
      WHERE UPPER(ui.custom_id) = v_code_upper;
      
    ELSE
      -- Recherche générique dans toutes les tables
      RETURN QUERY
      SELECT ui.user_id, p.role::TEXT, COALESCE(p.full_name, p.email), ui.custom_id
      FROM user_ids ui
      JOIN profiles p ON p.id = ui.user_id
      WHERE UPPER(ui.custom_id) = v_code_upper
      LIMIT 1;
  END CASE;
  
  RETURN;
END;
$$;

-- 10. Synchroniser les compteurs avec les données existantes
UPDATE id_counters 
SET current_value = COALESCE((
  SELECT MAX(NULLIF(regexp_replace(custom_id, '[^0-9]', '', 'g'), '')::INTEGER)
  FROM vendor_agents 
  WHERE custom_id LIKE 'VAG%'
), 0)
WHERE prefix = 'VAG';

UPDATE id_counters 
SET current_value = COALESCE((
  SELECT MAX(NULLIF(regexp_replace(custom_id, '[^0-9]', '', 'g'), '')::INTEGER)
  FROM members 
  WHERE custom_id LIKE 'MBR%'
), 0)
WHERE prefix = 'MBR';

UPDATE id_counters 
SET current_value = COALESCE((
  SELECT MAX(NULLIF(regexp_replace(agent_code, '[^0-9]', '', 'g'), '')::INTEGER)
  FROM agents_management 
  WHERE agent_code LIKE 'SAG%'
), 0)
WHERE prefix = 'SAG';

-- 11. Index pour améliorer les performances de recherche
CREATE INDEX IF NOT EXISTS idx_vendor_agents_custom_id ON vendor_agents(custom_id);
CREATE INDEX IF NOT EXISTS idx_members_custom_id ON members(custom_id);
CREATE INDEX IF NOT EXISTS idx_syndicate_workers_custom_id ON syndicate_workers(custom_id);
CREATE INDEX IF NOT EXISTS idx_agents_management_agent_code ON agents_management(agent_code);