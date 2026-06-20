-- Mettre à jour la fonction handle_new_user pour inclure le champ city
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

  -- Insérer le profil avec le champ city
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
    city,
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
    COALESCE(NEW.raw_user_meta_data->>'city', ''),
    true
  );

  RETURN NEW;
END;
$$;

-- Le trigger existe déjà, pas besoin de le recréer