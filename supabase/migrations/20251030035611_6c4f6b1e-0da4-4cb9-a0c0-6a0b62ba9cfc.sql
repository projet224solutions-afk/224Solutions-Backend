-- Mise à jour des codes agents au format AGE0001
DO $$
DECLARE
  agent_record RECORD;
  new_code TEXT;
  counter INTEGER := 1;
BEGIN
  -- Mettre à jour les agents (non sous-agents) avec des codes séquentiels
  FOR agent_record IN 
    SELECT id FROM agents_management 
    WHERE parent_agent_id IS NULL 
    ORDER BY created_at ASC
  LOOP
    new_code := 'AGE' || LPAD(counter::TEXT, 4, '0');
    UPDATE agents_management 
    SET agent_code = new_code 
    WHERE id = agent_record.id;
    counter := counter + 1;
  END LOOP;
  
  -- Mettre à jour les sous-agents avec des codes séquentiels
  counter := 1;
  FOR agent_record IN 
    SELECT id FROM agents_management 
    WHERE parent_agent_id IS NOT NULL 
    ORDER BY created_at ASC
  LOOP
    new_code := 'SAG' || LPAD(counter::TEXT, 4, '0');
    UPDATE agents_management 
    SET agent_code = new_code 
    WHERE id = agent_record.id;
    counter := counter + 1;
  END LOOP;
END $$;

-- Mise à jour des codes bureaux au format BST0001
DO $$
DECLARE
  bureau_record RECORD;
  new_code TEXT;
  counter INTEGER := 1;
BEGIN
  FOR bureau_record IN 
    SELECT id FROM bureaus 
    ORDER BY created_at ASC
  LOOP
    new_code := 'BST' || LPAD(counter::TEXT, 4, '0');
    UPDATE bureaus 
    SET bureau_code = new_code 
    WHERE id = bureau_record.id;
    counter := counter + 1;
  END LOOP;
END $$;

-- Créer une fonction pour générer automatiquement les codes agents
CREATE OR REPLACE FUNCTION generate_agent_code()
RETURNS TRIGGER AS $$
DECLARE
  prefix TEXT;
  next_number INTEGER;
  new_code TEXT;
BEGIN
  -- Déterminer le préfixe selon si c'est un agent ou sous-agent
  IF NEW.parent_agent_id IS NULL THEN
    prefix := 'AGE';
  ELSE
    prefix := 'SAG';
  END IF;
  
  -- Trouver le prochain numéro disponible
  SELECT COALESCE(MAX(CAST(SUBSTRING(agent_code FROM 4) AS INTEGER)), 0) + 1
  INTO next_number
  FROM agents_management
  WHERE agent_code LIKE prefix || '%';
  
  -- Générer le nouveau code
  new_code := prefix || LPAD(next_number::TEXT, 4, '0');
  NEW.agent_code := new_code;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Créer le trigger pour les agents
DROP TRIGGER IF EXISTS set_agent_code ON agents_management;
CREATE TRIGGER set_agent_code
  BEFORE INSERT ON agents_management
  FOR EACH ROW
  WHEN (NEW.agent_code IS NULL OR NEW.agent_code = '')
  EXECUTE FUNCTION generate_agent_code();

-- Créer une fonction pour générer automatiquement les codes bureaux
CREATE OR REPLACE FUNCTION generate_bureau_code()
RETURNS TRIGGER AS $$
DECLARE
  next_number INTEGER;
  new_code TEXT;
BEGIN
  -- Trouver le prochain numéro disponible
  SELECT COALESCE(MAX(CAST(SUBSTRING(bureau_code FROM 4) AS INTEGER)), 0) + 1
  INTO next_number
  FROM bureaus
  WHERE bureau_code LIKE 'BST%';
  
  -- Générer le nouveau code
  new_code := 'BST' || LPAD(next_number::TEXT, 4, '0');
  NEW.bureau_code := new_code;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Créer le trigger pour les bureaux
DROP TRIGGER IF EXISTS set_bureau_code ON bureaus;
CREATE TRIGGER set_bureau_code
  BEFORE INSERT ON bureaus
  FOR EACH ROW
  WHEN (NEW.bureau_code IS NULL OR NEW.bureau_code = '')
  EXECUTE FUNCTION generate_bureau_code();