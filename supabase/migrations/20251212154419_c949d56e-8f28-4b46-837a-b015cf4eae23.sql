
-- Supprimer l'ancienne fonction generate_custom_id_with_role
DROP FUNCTION IF EXISTS generate_custom_id_with_role(text);

-- Recréer la fonction generate_custom_id_with_role avec le format séquentiel
CREATE OR REPLACE FUNCTION generate_custom_id_with_role(p_role TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prefix TEXT;
  v_next_num INTEGER;
  v_new_id TEXT;
  v_exists INTEGER;
BEGIN
  -- Définir le préfixe selon le rôle
  CASE p_role
    WHEN 'client' THEN v_prefix := 'CLT';
    WHEN 'vendeur' THEN v_prefix := 'VND';
    WHEN 'admin' THEN v_prefix := 'PDG';
    WHEN 'ceo' THEN v_prefix := 'PDG';
    WHEN 'livreur' THEN v_prefix := 'DRV';
    WHEN 'taxi' THEN v_prefix := 'DRV';
    WHEN 'agent' THEN v_prefix := 'AGT';
    WHEN 'syndicat' THEN v_prefix := 'BST';
    WHEN 'transitaire' THEN v_prefix := 'TRS';
    ELSE v_prefix := 'CLT';
  END CASE;
  
  -- Récupérer et incrémenter le compteur
  UPDATE id_counters 
  SET current_value = current_value + 1, updated_at = NOW()
  WHERE prefix = v_prefix
  RETURNING current_value INTO v_next_num;
  
  -- Si pas de compteur, le créer
  IF v_next_num IS NULL THEN
    SELECT COALESCE(MAX(
      NULLIF(regexp_replace(custom_id, '^' || v_prefix, '', 'i'), '')::INTEGER
    ), 0) INTO v_next_num
    FROM user_ids 
    WHERE custom_id LIKE v_prefix || '%';
    
    v_next_num := v_next_num + 1;
    
    INSERT INTO id_counters (prefix, current_value, description)
    VALUES (v_prefix, v_next_num, 'Compteur ' || v_prefix)
    ON CONFLICT (prefix) DO UPDATE SET current_value = v_next_num;
  END IF;
  
  -- Générer l'ID avec padding (4 chiffres)
  v_new_id := v_prefix || LPAD(v_next_num::TEXT, 4, '0');
  
  -- Vérifier unicité
  SELECT COUNT(*) INTO v_exists FROM user_ids WHERE custom_id = v_new_id;
  
  WHILE v_exists > 0 LOOP
    v_next_num := v_next_num + 1;
    v_new_id := v_prefix || LPAD(v_next_num::TEXT, 4, '0');
    SELECT COUNT(*) INTO v_exists FROM user_ids WHERE custom_id = v_new_id;
    UPDATE id_counters SET current_value = v_next_num WHERE prefix = v_prefix;
  END LOOP;
  
  RETURN v_new_id;
END;
$$;

-- S'assurer que les compteurs existent pour tous les préfixes
INSERT INTO id_counters (prefix, current_value, description) VALUES
  ('CLT', 0, 'Compteur clients'),
  ('VND', 0, 'Compteur vendeurs'),
  ('DRV', 0, 'Compteur chauffeurs'),
  ('AGT', 0, 'Compteur agents'),
  ('BST', 0, 'Compteur bureaux'),
  ('PDG', 0, 'Compteur PDG'),
  ('TRS', 0, 'Compteur transitaires')
ON CONFLICT (prefix) DO NOTHING;

-- Mettre à jour les compteurs avec les valeurs max existantes
DO $$
DECLARE
  v_prefix TEXT;
  v_max_num INTEGER;
BEGIN
  FOR v_prefix IN SELECT DISTINCT prefix FROM id_counters LOOP
    SELECT COALESCE(MAX(
      NULLIF(regexp_replace(custom_id, '^' || v_prefix, '', 'i'), '')::INTEGER
    ), 0) INTO v_max_num
    FROM user_ids 
    WHERE custom_id LIKE v_prefix || '%';
    
    UPDATE id_counters SET current_value = v_max_num WHERE prefix = v_prefix;
  END LOOP;
END;
$$;
