-- Supprimer les anciens triggers qui causent des conflits
DROP TRIGGER IF EXISTS on_auth_user_created_custom_id ON auth.users;
DROP TRIGGER IF EXISTS on_auth_user_id_created ON auth.users;

-- Supprimer aussi les anciennes fonctions
DROP FUNCTION IF EXISTS public.create_user_custom_id_on_signup();
DROP FUNCTION IF EXISTS public.handle_new_user_id();
DROP FUNCTION IF EXISTS public.generate_role_based_custom_id(uuid);

-- Maintenant, modifier le trigger handle_new_user pour aussi créer dans user_ids si nécessaire
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_public_id TEXT;
  v_prefix TEXT;
BEGIN
  -- Déterminer le préfixe selon le rôle
  v_prefix := CASE 
    WHEN NEW.raw_user_meta_data->>'role' = 'vendeur' THEN 'VND'
    WHEN NEW.raw_user_meta_data->>'role' = 'livreur' THEN 'DRV'
    WHEN NEW.raw_user_meta_data->>'role' = 'taxi' THEN 'DRV'
    WHEN NEW.raw_user_meta_data->>'role' = 'admin' THEN 'PDG'
    WHEN NEW.raw_user_meta_data->>'role' = 'syndicat' THEN 'SYD'
    WHEN NEW.raw_user_meta_data->>'role' = 'transitaire' THEN 'AGT'
    ELSE 'USR'
  END;

  -- Générer l'ID séquentiel
  SELECT generate_sequential_id(v_prefix) INTO v_public_id;

  -- Insérer le profil
  INSERT INTO public.profiles (
    id,
    email,
    first_name,
    last_name,
    phone,
    role,
    public_id,
    custom_id,
    country,
    is_active
  )
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'first_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'last_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'phone', ''),
    COALESCE((NEW.raw_user_meta_data->>'role')::user_role, 'client'),
    v_public_id,
    v_public_id,
    COALESCE(NEW.raw_user_meta_data->>'country', 'Guinée'),
    true
  );

  -- Aussi insérer dans user_ids pour compatibilité
  INSERT INTO public.user_ids (user_id, custom_id)
  VALUES (NEW.id, v_public_id)
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
END;
$$;