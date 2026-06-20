-- Migration: Synchronisation automatique des profils utilisateurs avec Auth
-- Créer les profils manquants et configurer le trigger automatique

-- 1. Fonction pour créer automatiquement un profil lors de l'inscription
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_custom_id TEXT;
BEGIN
  -- Générer un custom_id unique
  v_custom_id := generate_custom_id();
  
  -- Créer le profil utilisateur
  INSERT INTO public.profiles (
    id, 
    email, 
    full_name,
    first_name,
    last_name,
    custom_id,
    role,
    created_at,
    updated_at
  )
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name', 'Utilisateur'),
    COALESCE(NEW.raw_user_meta_data->>'first_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'last_name', ''),
    v_custom_id,
    COALESCE(NEW.raw_user_meta_data->>'role', 'client')::user_role,
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO NOTHING;
  
  -- Créer l'entrée dans user_ids
  INSERT INTO public.user_ids (user_id, custom_id, created_at)
  VALUES (NEW.id, v_custom_id, NOW())
  ON CONFLICT (user_id) DO NOTHING;
  
  -- Initialiser le wallet
  INSERT INTO public.wallets (user_id, balance, currency, wallet_status, created_at, updated_at)
  VALUES (NEW.id, 0, 'GNF', 'active', NOW(), NOW())
  ON CONFLICT (user_id, currency) DO NOTHING;
  
  RETURN NEW;
END;
$$;

-- 2. Créer le trigger sur auth.users
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- 3. Fonction pour synchroniser les profils existants manquants
CREATE OR REPLACE FUNCTION public.sync_missing_profiles()
RETURNS TABLE(user_id UUID, custom_id TEXT, status TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user RECORD;
  v_custom_id TEXT;
BEGIN
  -- Parcourir tous les utilisateurs auth.users qui n'ont pas de profil
  FOR v_user IN 
    SELECT au.id, au.email, au.raw_user_meta_data
    FROM auth.users au
    LEFT JOIN public.profiles p ON au.id = p.id
    WHERE p.id IS NULL
  LOOP
    -- Générer un custom_id
    v_custom_id := generate_custom_id();
    
    -- Créer le profil
    INSERT INTO public.profiles (
      id, 
      email, 
      full_name,
      first_name,
      last_name,
      custom_id,
      role,
      created_at,
      updated_at
    )
    VALUES (
      v_user.id,
      v_user.email,
      COALESCE(v_user.raw_user_meta_data->>'full_name', v_user.raw_user_meta_data->>'name', 'Utilisateur'),
      COALESCE(v_user.raw_user_meta_data->>'first_name', ''),
      COALESCE(v_user.raw_user_meta_data->>'last_name', ''),
      v_custom_id,
      COALESCE(v_user.raw_user_meta_data->>'role', 'client')::user_role,
      NOW(),
      NOW()
    );
    
    -- Créer l'entrée dans user_ids
    INSERT INTO public.user_ids (user_id, custom_id, created_at)
    VALUES (v_user.id, v_custom_id, NOW())
    ON CONFLICT (user_id) DO NOTHING;
    
    -- Initialiser le wallet
    INSERT INTO public.wallets (user_id, balance, currency, wallet_status, created_at, updated_at)
    VALUES (v_user.id, 0, 'GNF', 'active', NOW(), NOW())
    ON CONFLICT (user_id, currency) DO NOTHING;
    
    user_id := v_user.id;
    custom_id := v_custom_id;
    status := 'created';
    RETURN NEXT;
  END LOOP;
END;
$$;

-- 4. Exécuter la synchronisation des profils manquants
SELECT * FROM public.sync_missing_profiles();

-- 5. Ajouter des commentaires pour la documentation
COMMENT ON FUNCTION public.handle_new_user() IS 'Trigger automatique pour créer un profil, user_id et wallet lors de l''inscription d''un utilisateur';
COMMENT ON FUNCTION public.sync_missing_profiles() IS 'Fonction pour synchroniser les profils manquants des utilisateurs auth.users existants';