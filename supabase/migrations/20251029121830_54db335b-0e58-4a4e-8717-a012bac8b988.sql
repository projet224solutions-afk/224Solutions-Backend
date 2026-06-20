-- Migration: Format d'ID basé sur le rôle utilisateur
-- Génère des IDs au format: PDG0001, VEN0001, CLI0001, TAX0001, LIV0001, AGT0001

-- 1. Fonction pour obtenir le préfixe selon le rôle
CREATE OR REPLACE FUNCTION get_role_prefix(user_role TEXT)
RETURNS TEXT AS $$
BEGIN
  RETURN CASE user_role
    WHEN 'admin' THEN 'PDG'
    WHEN 'vendeur' THEN 'VEN'
    WHEN 'client' THEN 'CLI'
    WHEN 'taxi' THEN 'TAX'
    WHEN 'livreur' THEN 'LIV'
    WHEN 'agent' THEN 'AGT'
    WHEN 'sub_agent' THEN 'SAG'
    WHEN 'syndicate_member' THEN 'SYN'
    WHEN 'bureau' THEN 'BUR'
    ELSE 'USR'
  END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 2. Fonction pour générer un custom_id basé sur le rôle
CREATE OR REPLACE FUNCTION generate_role_based_custom_id(user_id_param UUID)
RETURNS TEXT AS $$
DECLARE
  user_role TEXT;
  prefix TEXT;
  next_number INT;
  new_id TEXT;
  exists_check INT;
BEGIN
  -- Récupérer le rôle de l'utilisateur
  SELECT role INTO user_role
  FROM profiles
  WHERE id = user_id_param;
  
  -- Si pas de rôle trouvé, utiliser 'client' par défaut
  IF user_role IS NULL THEN
    user_role := 'client';
  END IF;
  
  -- Obtenir le préfixe
  prefix := get_role_prefix(user_role);
  
  -- Trouver le prochain numéro disponible pour ce préfixe
  LOOP
    SELECT COALESCE(MAX(
      CASE 
        WHEN custom_id ~ ('^' || prefix || '[0-9]{4}$')
        THEN CAST(SUBSTRING(custom_id FROM '[0-9]+$') AS INTEGER)
        ELSE 0
      END
    ), 0) + 1
    INTO next_number
    FROM user_ids
    WHERE custom_id LIKE (prefix || '%');
    
    -- Générer le nouvel ID
    new_id := prefix || LPAD(next_number::TEXT, 4, '0');
    
    -- Vérifier l'unicité
    SELECT COUNT(*) INTO exists_check
    FROM user_ids
    WHERE custom_id = new_id;
    
    EXIT WHEN exists_check = 0;
    
    -- Si collision (rare), incrémenter et réessayer
    next_number := next_number + 1;
  END LOOP;
  
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. Mettre à jour la fonction de création automatique
CREATE OR REPLACE FUNCTION create_user_custom_id_on_signup()
RETURNS TRIGGER AS $$
BEGIN
  -- Insérer dans user_ids avec un custom_id basé sur le rôle
  INSERT INTO user_ids (user_id, custom_id)
  VALUES (NEW.id, generate_role_based_custom_id(NEW.id))
  ON CONFLICT (user_id) DO NOTHING;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Fonction pour mettre à jour un custom_id existant (appelée après changement de rôle)
CREATE OR REPLACE FUNCTION update_custom_id_on_role_change()
RETURNS TRIGGER AS $$
BEGIN
  -- Si le rôle a changé, générer un nouveau custom_id
  IF OLD.role IS DISTINCT FROM NEW.role THEN
    UPDATE user_ids
    SET custom_id = generate_role_based_custom_id(NEW.id)
    WHERE user_id = NEW.id;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Créer le trigger pour mise à jour automatique lors du changement de rôle
DROP TRIGGER IF EXISTS on_profile_role_changed ON profiles;
CREATE TRIGGER on_profile_role_changed
  AFTER UPDATE OF role ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION update_custom_id_on_role_change();

-- 6. Mettre à jour TOUS les custom_id existants avec le nouveau format
DO $$
DECLARE
  user_record RECORD;
  new_custom_id TEXT;
BEGIN
  FOR user_record IN 
    SELECT ui.user_id, p.role
    FROM user_ids ui
    JOIN profiles p ON p.id = ui.user_id
  LOOP
    new_custom_id := generate_role_based_custom_id(user_record.user_id);
    
    UPDATE user_ids
    SET custom_id = new_custom_id
    WHERE user_id = user_record.user_id;
    
    RAISE NOTICE 'Mis à jour: % -> %', user_record.user_id, new_custom_id;
  END LOOP;
END $$;

-- 7. Commentaires pour documentation
COMMENT ON FUNCTION get_role_prefix(TEXT) IS 'Retourne le préfixe de 3 lettres selon le rôle utilisateur';
COMMENT ON FUNCTION generate_role_based_custom_id(UUID) IS 'Génère un ID unique basé sur le rôle au format PREFIXE0001';
COMMENT ON FUNCTION update_custom_id_on_role_change() IS 'Met à jour automatiquement le custom_id quand le rôle change';