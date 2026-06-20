-- 🔧 TRIGGER: GÉNÉRATION AUTOMATIQUE D'ID STANDARDISÉ À L'INSCRIPTION
-- Génère automatiquement un ID standardisé pour tous les nouveaux utilisateurs

-- Fonction trigger pour générer l'ID à l'inscription
CREATE OR REPLACE FUNCTION public.auto_generate_standard_id_on_signup()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_prefix VARCHAR(3);
  v_new_id TEXT;
BEGIN
  -- Si un public_id existe déjà, ne rien faire
  IF NEW.public_id IS NOT NULL AND NEW.public_id != '' THEN
    RETURN NEW;
  END IF;

  -- Déterminer le préfixe selon le rôle
  v_prefix := CASE 
    WHEN NEW.role = 'vendeur' THEN 'VND'
    WHEN NEW.role = 'livreur' THEN 'DRV'
    WHEN NEW.role = 'taxi' THEN 'DRV'
    WHEN NEW.role = 'admin' THEN 'PDG'
    WHEN NEW.role = 'syndicat' THEN 'SYD'
    WHEN NEW.role = 'transitaire' THEN 'AGT'
    ELSE 'USR'  -- Client ou autre
  END;

  -- Générer l'ID standardisé
  v_new_id := generate_sequential_id(v_prefix);

  -- Assigner l'ID au nouveau profil
  NEW.public_id := v_new_id;

  RETURN NEW;
END;
$$;

-- Supprimer l'ancien trigger s'il existe
DROP TRIGGER IF EXISTS trigger_auto_generate_standard_id ON public.profiles;

-- Créer le trigger pour les nouveaux utilisateurs
CREATE TRIGGER trigger_auto_generate_standard_id
  BEFORE INSERT ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.auto_generate_standard_id_on_signup();

-- Mettre à jour les utilisateurs existants sans public_id
DO $$
DECLARE
  v_profile RECORD;
  v_prefix VARCHAR(3);
  v_new_id TEXT;
BEGIN
  FOR v_profile IN 
    SELECT id, role 
    FROM public.profiles 
    WHERE public_id IS NULL OR public_id = ''
  LOOP
    -- Déterminer le préfixe
    v_prefix := CASE 
      WHEN v_profile.role = 'vendeur' THEN 'VND'
      WHEN v_profile.role = 'livreur' THEN 'DRV'
      WHEN v_profile.role = 'taxi' THEN 'DRV'
      WHEN v_profile.role = 'admin' THEN 'PDG'
      WHEN v_profile.role = 'syndicat' THEN 'SYD'
      WHEN v_profile.role = 'transitaire' THEN 'AGT'
      ELSE 'USR'
    END;

    -- Générer l'ID
    v_new_id := generate_sequential_id(v_prefix);

    -- Mettre à jour le profil
    UPDATE public.profiles
    SET public_id = v_new_id
    WHERE id = v_profile.id;

    RAISE NOTICE 'ID généré pour profil %: %', v_profile.id, v_new_id;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.auto_generate_standard_id_on_signup() IS 'Génère automatiquement un ID standardisé lors de l''inscription';
COMMENT ON TRIGGER trigger_auto_generate_standard_id ON public.profiles IS 'Trigger pour génération automatique d''ID standardisé';