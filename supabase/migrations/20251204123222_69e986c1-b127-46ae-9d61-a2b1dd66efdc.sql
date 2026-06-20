-- Corriger la fonction find_user_by_code pour inclure les agents
CREATE OR REPLACE FUNCTION find_user_by_code(p_code TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  -- 1. Chercher dans agents_management (agent_code -> user_id)
  SELECT user_id INTO v_user_id
  FROM agents_management
  WHERE agent_code = UPPER(p_code)
  AND user_id IS NOT NULL
  LIMIT 1;
  
  IF v_user_id IS NOT NULL THEN
    RETURN v_user_id;
  END IF;
  
  -- 2. Chercher dans user_ids (custom_id -> user_id)
  SELECT user_id INTO v_user_id
  FROM user_ids
  WHERE custom_id = UPPER(p_code)
  LIMIT 1;
  
  IF v_user_id IS NOT NULL THEN
    RETURN v_user_id;
  END IF;
  
  -- 3. Chercher dans profiles (custom_id -> id)
  SELECT id INTO v_user_id
  FROM profiles
  WHERE custom_id = UPPER(p_code)
  LIMIT 1;
  
  IF v_user_id IS NOT NULL THEN
    RETURN v_user_id;
  END IF;
  
  -- 4. Chercher dans profiles (public_id -> id)
  SELECT id INTO v_user_id
  FROM profiles
  WHERE public_id = UPPER(p_code)
  LIMIT 1;
  
  IF v_user_id IS NOT NULL THEN
    RETURN v_user_id;
  END IF;
  
  -- 5. Chercher dans bureaus (bureau_code -> id du président si disponible)
  SELECT p.id INTO v_user_id
  FROM bureaus b
  JOIN profiles p ON p.email = b.president_email
  WHERE b.bureau_code = UPPER(p_code)
  LIMIT 1;
  
  RETURN v_user_id;
END;
$$;