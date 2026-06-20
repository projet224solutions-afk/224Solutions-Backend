-- =======================================================================
-- CORRECTION FORMAT ID TAXI/LIVREUR: TAX0001 et LIV0001
-- =======================================================================
-- Problème: Les comptes taxi/livreur reçoivent DRV0001 au lieu de TAX0001/LIV0001
-- Solution: Corriger la fonction et les IDs existants
-- =======================================================================

-- 1. Ajouter les nouveaux compteurs TAX et LIV
INSERT INTO id_counters (prefix, current_value, description) VALUES
  ('TAX', 0, 'Compteur taxis'),
  ('LIV', 0, 'Compteur livreurs')
ON CONFLICT (prefix) DO NOTHING;

-- 2. Corriger la fonction generate_custom_id_with_role
DROP FUNCTION IF EXISTS generate_custom_id_with_role(TEXT);

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
    WHEN 'pdg' THEN v_prefix := 'PDG';
    WHEN 'livreur' THEN v_prefix := 'LIV';  -- CORRIGÉ: LIV au lieu de DRV
    WHEN 'taxi' THEN v_prefix := 'TAX';     -- CORRIGÉ: TAX au lieu de DRV
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

GRANT EXECUTE ON FUNCTION generate_custom_id_with_role(TEXT) TO authenticated;

-- 3. Corriger les IDs existants des taxis (DRV → TAX)
DO $$
DECLARE
  v_record RECORD;
  v_new_id TEXT;
  v_next_num INT;
BEGIN
  -- Pour chaque taxi avec un mauvais préfixe
  FOR v_record IN
    SELECT p.id, p.custom_id, ui.custom_id as ui_custom_id
    FROM profiles p
    LEFT JOIN user_ids ui ON p.id = ui.user_id
    WHERE p.role = 'taxi' AND (p.custom_id LIKE 'DRV%' OR ui.custom_id LIKE 'DRV%')
  LOOP
    -- Obtenir le prochain numéro TAX
    SELECT COALESCE(MAX(SUBSTRING(custom_id FROM 4)::INT), 0) + 1 INTO v_next_num
    FROM user_ids
    WHERE custom_id LIKE 'TAX%';

    v_new_id := 'TAX' || LPAD(v_next_num::TEXT, 4, '0');

    -- Mettre à jour profiles
    UPDATE profiles
    SET custom_id = v_new_id, public_id = v_new_id, updated_at = NOW()
    WHERE id = v_record.id;

    -- Mettre à jour user_ids
    UPDATE user_ids
    SET custom_id = v_new_id, updated_at = NOW()
    WHERE user_id = v_record.id;

    -- Mettre à jour le compteur
    UPDATE id_counters SET current_value = v_next_num WHERE prefix = 'TAX';

    RAISE NOTICE '✅ Taxi corrigé: % → %', COALESCE(v_record.custom_id, v_record.ui_custom_id), v_new_id;
  END LOOP;
END $$;

-- 4. Corriger les IDs existants des livreurs (DRV → LIV)
DO $$
DECLARE
  v_record RECORD;
  v_new_id TEXT;
  v_next_num INT;
BEGIN
  -- Pour chaque livreur avec un mauvais préfixe
  FOR v_record IN
    SELECT p.id, p.custom_id, ui.custom_id as ui_custom_id
    FROM profiles p
    LEFT JOIN user_ids ui ON p.id = ui.user_id
    WHERE p.role = 'livreur' AND (p.custom_id LIKE 'DRV%' OR ui.custom_id LIKE 'DRV%')
  LOOP
    -- Obtenir le prochain numéro LIV
    SELECT COALESCE(MAX(SUBSTRING(custom_id FROM 4)::INT), 0) + 1 INTO v_next_num
    FROM user_ids
    WHERE custom_id LIKE 'LIV%';

    v_new_id := 'LIV' || LPAD(v_next_num::TEXT, 4, '0');

    -- Mettre à jour profiles
    UPDATE profiles
    SET custom_id = v_new_id, public_id = v_new_id, updated_at = NOW()
    WHERE id = v_record.id;

    -- Mettre à jour user_ids
    UPDATE user_ids
    SET custom_id = v_new_id, updated_at = NOW()
    WHERE user_id = v_record.id;

    -- Mettre à jour le compteur
    UPDATE id_counters SET current_value = v_next_num WHERE prefix = 'LIV';

    RAISE NOTICE '✅ Livreur corrigé: % → %', COALESCE(v_record.custom_id, v_record.ui_custom_id), v_new_id;
  END LOOP;
END $$;

-- 5. Mettre à jour les compteurs avec les valeurs actuelles
UPDATE id_counters SET current_value = (
  SELECT COALESCE(MAX(SUBSTRING(custom_id FROM 4)::INT), 0)
  FROM user_ids WHERE custom_id LIKE 'TAX%'
) WHERE prefix = 'TAX';

UPDATE id_counters SET current_value = (
  SELECT COALESCE(MAX(SUBSTRING(custom_id FROM 4)::INT), 0)
  FROM user_ids WHERE custom_id LIKE 'LIV%'
) WHERE prefix = 'LIV';

-- 6. Confirmation
DO $$
BEGIN
  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════════════════════════';
  RAISE NOTICE '✅ FORMAT ID TAXI/LIVREUR CORRIGÉ';
  RAISE NOTICE '═══════════════════════════════════════════════════════════════';
  RAISE NOTICE '• Taxi: TAX0001, TAX0002, ...';
  RAISE NOTICE '• Livreur: LIV0001, LIV0002, ...';
  RAISE NOTICE '• Les nouveaux comptes recevront automatiquement le bon format';
  RAISE NOTICE '═══════════════════════════════════════════════════════════════';
END $$;
