-- Système d'ID standardisé 224SOLUTIONS : AAA0001 (préfixe + séquentiel)

-- 1. Table pour gérer les séquences par préfixe
CREATE TABLE IF NOT EXISTS global_ids (
  id SERIAL PRIMARY KEY,
  prefix VARCHAR(3) NOT NULL UNIQUE,
  last_number BIGINT DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Initialiser les préfixes standards
INSERT INTO global_ids (prefix, last_number) VALUES
  ('USR', 0),
  ('VND', 0),
  ('DRV', 0),
  ('AGT', 0),
  ('SYD', 0),
  ('PDG', 0)
ON CONFLICT (prefix) DO NOTHING;

-- 2. Fonction pour générer un ID standardisé avec préfixe
CREATE OR REPLACE FUNCTION generate_standard_id(p_prefix VARCHAR(3))
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_number BIGINT;
  v_formatted_number TEXT;
  v_zero_count INT;
  v_unique_id TEXT;
BEGIN
  -- Verrouiller la ligne pour éviter les conflits de concurrence
  SELECT last_number INTO v_new_number
  FROM global_ids
  WHERE prefix = p_prefix
  FOR UPDATE;

  -- Incrémenter le numéro
  v_new_number := COALESCE(v_new_number, 0) + 1;

  -- Mettre à jour la séquence
  UPDATE global_ids
  SET last_number = v_new_number,
      updated_at = NOW()
  WHERE prefix = p_prefix;

  -- Formater le numéro avec au moins 4 chiffres (extensible)
  v_zero_count := GREATEST(4, LENGTH(v_new_number::TEXT));
  v_formatted_number := LPAD(v_new_number::TEXT, v_zero_count, '0');

  -- Construire l'ID final
  v_unique_id := p_prefix || v_formatted_number;

  RETURN v_unique_id;
END;
$$;

-- 3. Fonction pour déterminer le préfixe selon le rôle
CREATE OR REPLACE FUNCTION get_prefix_for_role(p_role TEXT)
RETURNS VARCHAR(3)
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN CASE
    WHEN p_role = 'client' THEN 'USR'
    WHEN p_role = 'vendeur' THEN 'VND'
    WHEN p_role IN ('livreur', 'taxi') THEN 'DRV'
    WHEN p_role = 'agent' THEN 'AGT'
    WHEN p_role = 'syndicat' THEN 'SYD'
    WHEN p_role = 'admin' THEN 'PDG'
    ELSE 'USR' -- fallback
  END;
END;
$$;

-- 4. Trigger pour générer automatiquement le custom_id lors de l'insertion dans profiles
CREATE OR REPLACE FUNCTION auto_generate_custom_id()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prefix VARCHAR(3);
  v_new_id TEXT;
BEGIN
  -- Si custom_id est déjà défini, ne rien faire
  IF NEW.custom_id IS NOT NULL AND NEW.custom_id != '' THEN
    RETURN NEW;
  END IF;

  -- Déterminer le préfixe selon le rôle
  v_prefix := get_prefix_for_role(NEW.role::TEXT);

  -- Générer le nouvel ID
  v_new_id := generate_standard_id(v_prefix);

  -- Assigner le custom_id
  NEW.custom_id := v_new_id;

  RETURN NEW;
END;
$$;

-- Créer le trigger sur profiles
DROP TRIGGER IF EXISTS trigger_auto_generate_custom_id ON profiles;
CREATE TRIGGER trigger_auto_generate_custom_id
  BEFORE INSERT ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION auto_generate_custom_id();

-- 5. Réorganiser les IDs existants selon le nouveau format
DO $$
DECLARE
  v_profile RECORD;
  v_prefix VARCHAR(3);
  v_new_id TEXT;
BEGIN
  -- Parcourir tous les profils
  FOR v_profile IN 
    SELECT id, role 
    FROM profiles 
    WHERE role IS NOT NULL
    ORDER BY created_at ASC
  LOOP
    -- Déterminer le préfixe
    v_prefix := get_prefix_for_role(v_profile.role::TEXT);
    
    -- Générer un nouvel ID
    v_new_id := generate_standard_id(v_prefix);
    
    -- Mettre à jour le profil
    UPDATE profiles
    SET custom_id = v_new_id
    WHERE id = v_profile.id;
    
    -- Mettre à jour user_ids si l'enregistrement existe
    UPDATE user_ids
    SET custom_id = v_new_id
    WHERE user_id = v_profile.id;
    
    -- Si pas d'enregistrement dans user_ids, en créer un
    INSERT INTO user_ids (user_id, custom_id, created_at)
    VALUES (v_profile.id, v_new_id, NOW())
    ON CONFLICT (user_id) DO UPDATE SET custom_id = EXCLUDED.custom_id;
  END LOOP;
  
  RAISE NOTICE 'Réorganisation des IDs terminée';
END;
$$;

-- 6. Fonction helper pour obtenir le custom_id d'un utilisateur
CREATE OR REPLACE FUNCTION get_user_custom_id(p_user_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_custom_id TEXT;
BEGIN
  SELECT custom_id INTO v_custom_id
  FROM profiles
  WHERE id = p_user_id;
  
  RETURN v_custom_id;
END;
$$;

-- Index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_profiles_custom_id ON profiles(custom_id);
CREATE INDEX IF NOT EXISTS idx_user_ids_custom_id ON user_ids(custom_id);
CREATE INDEX IF NOT EXISTS idx_global_ids_prefix ON global_ids(prefix);