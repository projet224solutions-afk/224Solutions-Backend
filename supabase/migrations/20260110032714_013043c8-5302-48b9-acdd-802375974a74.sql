-- Corriger la fonction de génération d'ID avec les bons préfixes standards
CREATE OR REPLACE FUNCTION public.generate_unique_public_id(user_role_param text DEFAULT 'client'::text)
RETURNS text
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  new_id text;
  prefix text;
  next_val int;
BEGIN
  -- Mapper le rôle vers le préfixe standard
  CASE user_role_param
    WHEN 'client' THEN prefix := 'CLI';
    WHEN 'vendeur' THEN prefix := 'VND';
    WHEN 'agent' THEN prefix := 'AGT';
    WHEN 'livreur' THEN prefix := 'DRV';
    WHEN 'admin' THEN prefix := 'ADM';
    WHEN 'pdg' THEN prefix := 'PDG';
    WHEN 'syndicat' THEN prefix := 'SYD';
    WHEN 'taxi' THEN prefix := 'DRV';
    WHEN 'transitaire' THEN prefix := 'TRS';
    ELSE prefix := 'USR';
  END CASE;
  
  -- Utiliser le système de compteur séquentiel
  -- Créer le compteur s'il n'existe pas
  INSERT INTO public.id_counters (prefix, current_value, description)
  VALUES (prefix, 0, 'Auto-créé pour ' || user_role_param)
  ON CONFLICT (prefix) DO NOTHING;
  
  -- Incrémenter et obtenir la nouvelle valeur de façon atomique
  UPDATE public.id_counters 
  SET current_value = current_value + 1, updated_at = now()
  WHERE prefix = prefix
  RETURNING current_value INTO next_val;
  
  -- Générer l'ID final: PREFIX + 4 chiffres
  new_id := prefix || LPAD(next_val::text, 4, '0');
  
  RETURN new_id;
END;
$function$;

-- Créer un trigger pour auto-générer public_id sur les nouveaux profils
CREATE OR REPLACE FUNCTION public.auto_generate_profile_public_id()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  prefix text;
  next_val int;
BEGIN
  -- Ne rien faire si public_id est déjà défini et valide
  IF NEW.public_id IS NOT NULL AND NEW.public_id ~ '^[A-Z]{3}[0-9]{4}$' THEN
    RETURN NEW;
  END IF;
  
  -- Mapper le rôle vers le préfixe standard
  CASE COALESCE(NEW.role, 'client')
    WHEN 'client' THEN prefix := 'CLI';
    WHEN 'vendeur' THEN prefix := 'VND';
    WHEN 'agent' THEN prefix := 'AGT';
    WHEN 'livreur' THEN prefix := 'DRV';
    WHEN 'admin' THEN prefix := 'ADM';
    WHEN 'pdg' THEN prefix := 'PDG';
    WHEN 'syndicat' THEN prefix := 'SYD';
    WHEN 'taxi' THEN prefix := 'DRV';
    WHEN 'transitaire' THEN prefix := 'TRS';
    ELSE prefix := 'USR';
  END CASE;
  
  -- Créer le compteur s'il n'existe pas
  INSERT INTO public.id_counters (prefix, current_value, description)
  VALUES (prefix, 0, 'Auto-créé pour ' || COALESCE(NEW.role, 'client'))
  ON CONFLICT (prefix) DO NOTHING;
  
  -- Incrémenter et obtenir la nouvelle valeur de façon atomique
  UPDATE public.id_counters 
  SET current_value = current_value + 1, updated_at = now()
  WHERE id_counters.prefix = prefix
  RETURNING current_value INTO next_val;
  
  -- Générer l'ID final: PREFIX + 4 chiffres
  NEW.public_id := prefix || LPAD(next_val::text, 4, '0');
  
  RETURN NEW;
END;
$function$;

-- Supprimer l'ancien trigger s'il existe
DROP TRIGGER IF EXISTS trigger_auto_generate_profile_public_id ON public.profiles;

-- Créer le trigger sur INSERT
CREATE TRIGGER trigger_auto_generate_profile_public_id
  BEFORE INSERT ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.auto_generate_profile_public_id();

-- Créer aussi un trigger pour UPDATE si le rôle change et l'ID est ancien format
CREATE OR REPLACE FUNCTION public.update_profile_public_id_on_role_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  prefix text;
  next_val int;
  expected_prefix text;
BEGIN
  -- Seulement si le rôle a changé
  IF OLD.role IS DISTINCT FROM NEW.role THEN
    -- Déterminer le nouveau préfixe attendu
    CASE COALESCE(NEW.role, 'client')
      WHEN 'client' THEN expected_prefix := 'CLI';
      WHEN 'vendeur' THEN expected_prefix := 'VND';
      WHEN 'agent' THEN expected_prefix := 'AGT';
      WHEN 'livreur' THEN expected_prefix := 'DRV';
      WHEN 'admin' THEN expected_prefix := 'ADM';
      WHEN 'pdg' THEN expected_prefix := 'PDG';
      WHEN 'syndicat' THEN expected_prefix := 'SYD';
      WHEN 'taxi' THEN expected_prefix := 'DRV';
      WHEN 'transitaire' THEN expected_prefix := 'TRS';
      ELSE expected_prefix := 'USR';
    END CASE;
    
    -- Si l'ID actuel ne correspond pas au nouveau rôle, le régénérer
    IF NEW.public_id IS NULL OR NOT NEW.public_id LIKE expected_prefix || '%' THEN
      prefix := expected_prefix;
      
      -- Créer le compteur s'il n'existe pas
      INSERT INTO public.id_counters (prefix, current_value, description)
      VALUES (prefix, 0, 'Auto-créé pour ' || COALESCE(NEW.role, 'client'))
      ON CONFLICT (prefix) DO NOTHING;
      
      -- Incrémenter atomiquement
      UPDATE public.id_counters 
      SET current_value = current_value + 1, updated_at = now()
      WHERE id_counters.prefix = prefix
      RETURNING current_value INTO next_val;
      
      NEW.public_id := prefix || LPAD(next_val::text, 4, '0');
    END IF;
  END IF;
  
  RETURN NEW;
END;
$function$;

-- Supprimer l'ancien trigger s'il existe
DROP TRIGGER IF EXISTS trigger_update_profile_public_id_on_role_change ON public.profiles;

-- Créer le trigger sur UPDATE
CREATE TRIGGER trigger_update_profile_public_id_on_role_change
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.update_profile_public_id_on_role_change();