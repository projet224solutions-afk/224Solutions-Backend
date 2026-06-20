-- =====================================================
-- MIGRATION: Corriger la contrainte de format driver_code
-- Accepter TAX, LIV et DRV comme préfixes valides
-- =====================================================

-- 1. Supprimer l'ancienne contrainte restrictive
ALTER TABLE taxi_drivers DROP CONSTRAINT IF EXISTS check_taxi_driver_code_format;

-- 2. Ajouter une nouvelle contrainte acceptant TAX, LIV et DRV
ALTER TABLE taxi_drivers 
ADD CONSTRAINT check_taxi_driver_code_format 
CHECK (
  driver_code IS NULL 
  OR driver_code ~ '^(TAX|LIV|DRV)[0-9]{4,}$'
);

-- 3. Synchroniser user_ids pour les taxis
UPDATE user_ids ui
SET custom_id = p.public_id
FROM profiles p
WHERE ui.user_id = p.id
  AND p.role = 'taxi'
  AND p.public_id IS NOT NULL
  AND p.public_id LIKE 'TAX%'
  AND ui.custom_id != p.public_id;

-- 4. Synchroniser user_ids pour les livreurs
UPDATE user_ids ui
SET custom_id = p.public_id
FROM profiles p
WHERE ui.user_id = p.id
  AND p.role = 'livreur'
  AND p.public_id IS NOT NULL
  AND p.public_id LIKE 'LIV%'
  AND ui.custom_id != p.public_id;

-- 5. Mettre à jour taxi_drivers.driver_code
UPDATE taxi_drivers td
SET driver_code = p.public_id
FROM profiles p
WHERE td.user_id = p.id
  AND p.public_id IS NOT NULL
  AND (p.public_id LIKE 'TAX%' OR p.public_id LIKE 'LIV%')
  AND td.driver_code != p.public_id;

-- 6. Synchroniser profiles.custom_id avec public_id
UPDATE profiles
SET custom_id = public_id
WHERE role IN ('taxi', 'livreur')
  AND public_id IS NOT NULL
  AND (custom_id IS NULL OR custom_id != public_id);

-- 7. Insérer les entrées manquantes dans user_ids
INSERT INTO user_ids (user_id, custom_id)
SELECT p.id, p.public_id
FROM profiles p
WHERE p.role IN ('taxi', 'livreur')
  AND p.public_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM user_ids ui WHERE ui.user_id = p.id)
ON CONFLICT (user_id) DO UPDATE SET custom_id = EXCLUDED.custom_id;

-- 8. Mettre à jour les compteurs TAX et LIV
INSERT INTO id_counters (prefix, current_value)
SELECT 'TAX', COALESCE(MAX(NULLIF(regexp_replace(public_id, '[^0-9]', '', 'g'), '')::int), 0)
FROM profiles WHERE public_id LIKE 'TAX%'
ON CONFLICT (prefix) DO UPDATE SET current_value = EXCLUDED.current_value;

INSERT INTO id_counters (prefix, current_value)
SELECT 'LIV', COALESCE(MAX(NULLIF(regexp_replace(public_id, '[^0-9]', '', 'g'), '')::int), 0)
FROM profiles WHERE public_id LIKE 'LIV%'
ON CONFLICT (prefix) DO UPDATE SET current_value = EXCLUDED.current_value;

-- 9. Améliorer la fonction de résolution d'ID (recherche prioritaire dans profiles.public_id)
CREATE OR REPLACE FUNCTION resolve_user_for_subscription(p_identifier TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_identifier TEXT;
BEGIN
  v_identifier := TRIM(UPPER(p_identifier));
  IF v_identifier IS NULL OR v_identifier = '' THEN RETURN NULL; END IF;

  -- 1. public_id dans profiles (TAX0001, LIV0001, VND0001, etc.) - PRIORITAIRE
  SELECT id INTO v_user_id FROM profiles WHERE UPPER(public_id) = v_identifier LIMIT 1;
  IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

  -- 2. Email exact
  SELECT id INTO v_user_id FROM profiles WHERE LOWER(email) = LOWER(p_identifier) LIMIT 1;
  IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

  -- 3. Téléphone
  SELECT id INTO v_user_id FROM profiles
  WHERE phone = p_identifier
     OR phone = REPLACE(p_identifier, ' ', '')
     OR REPLACE(REPLACE(phone, ' ', ''), '+', '') = REPLACE(REPLACE(p_identifier, ' ', ''), '+', '')
  LIMIT 1;
  IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

  -- 4. custom_id dans profiles
  SELECT id INTO v_user_id FROM profiles WHERE UPPER(custom_id) = v_identifier LIMIT 1;
  IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

  -- 5. custom_id dans user_ids
  SELECT user_id INTO v_user_id FROM user_ids WHERE UPPER(custom_id) = v_identifier LIMIT 1;
  IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

  -- 6. driver_code dans taxi_drivers
  SELECT user_id INTO v_user_id FROM taxi_drivers WHERE UPPER(driver_code) = v_identifier LIMIT 1;
  IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

  -- 7. Recherche par numéro seul (ajoute préfixes)
  IF v_identifier ~ '^[0-9]+$' THEN
    SELECT id INTO v_user_id FROM profiles WHERE public_id = 'TAX' || LPAD(v_identifier, 4, '0') LIMIT 1;
    IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

    SELECT id INTO v_user_id FROM profiles WHERE public_id = 'LIV' || LPAD(v_identifier, 4, '0') LIMIT 1;
    IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;

    SELECT id INTO v_user_id FROM profiles WHERE public_id = 'DRV' || LPAD(v_identifier, 4, '0') LIMIT 1;
    IF v_user_id IS NOT NULL THEN RETURN v_user_id; END IF;
  END IF;

  -- 8. Recherche partielle
  SELECT id INTO v_user_id FROM profiles WHERE UPPER(public_id) LIKE '%' || v_identifier || '%' LIMIT 1;

  RETURN v_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION resolve_user_for_subscription(TEXT) TO authenticated;