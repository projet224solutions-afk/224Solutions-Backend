-- Correction fonction find_user_by_code pour supporter les bureaux syndicats
-- Cette fonction permet de trouver les utilisateurs par leur code (BST, AGT, VND, etc.)

CREATE OR REPLACE FUNCTION find_user_by_code(p_code TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_bureau_id UUID;
BEGIN
  -- 1. Chercher dans user_ids (custom_id)
  SELECT user_id INTO v_user_id
  FROM user_ids
  WHERE custom_id = UPPER(p_code)
  LIMIT 1;
  
  IF v_user_id IS NOT NULL THEN
    RETURN v_user_id;
  END IF;
  
  -- 2. Chercher dans profiles (custom_id)
  SELECT id INTO v_user_id
  FROM profiles
  WHERE custom_id = UPPER(p_code)
  LIMIT 1;
  
  IF v_user_id IS NOT NULL THEN
    RETURN v_user_id;
  END IF;
  
  -- 3. Chercher dans profiles (public_id)
  SELECT id INTO v_user_id
  FROM profiles
  WHERE public_id = UPPER(p_code)
  LIMIT 1;
  
  IF v_user_id IS NOT NULL THEN
    RETURN v_user_id;
  END IF;
  
  -- 4. NOUVEAU: Chercher dans bureau_syndicats par bureau_code
  -- Les bureaux syndicats ont des codes comme BST0001, BST0002, etc.
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'bureau_syndicats') THEN
    SELECT id, user_id INTO v_bureau_id, v_user_id
    FROM bureau_syndicats
    WHERE bureau_code = UPPER(p_code)
    LIMIT 1;
    
    IF v_user_id IS NOT NULL THEN
      RETURN v_user_id;
    END IF;
    
    -- Si pas de user_id mais bureau_id existe, retourner le bureau_id
    -- (pour compatibilité avec wallet bureau)
    IF v_bureau_id IS NOT NULL THEN
      RETURN v_bureau_id;
    END IF;
  END IF;
  
  -- Rien trouvé
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION find_user_by_code(TEXT) IS 'Trouve un utilisateur par son code (custom_id, public_id, ou bureau_code). Supporte: USR, VND, AGT, BST, etc.';

-- Accorder permissions
GRANT EXECUTE ON FUNCTION find_user_by_code(TEXT) TO authenticated, anon;
