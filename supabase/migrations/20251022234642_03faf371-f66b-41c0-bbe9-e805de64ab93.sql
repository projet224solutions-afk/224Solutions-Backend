-- Créer ou remplacer la fonction trigger pour créer automatiquement les profils
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (
    id,
    email,
    first_name,
    last_name,
    role,
    phone,
    is_active,
    status
  )
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'first_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'last_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'role', 'client'),
    COALESCE(NEW.raw_user_meta_data->>'phone', ''),
    true,
    'offline'
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Supprimer le trigger existant s'il existe
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

-- Créer le trigger pour appeler la fonction lors de la création d'un utilisateur
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- Créer ou remplacer la fonction trigger pour créer l'ID utilisateur
CREATE OR REPLACE FUNCTION public.handle_new_user_id()
RETURNS TRIGGER AS $$
DECLARE
  v_custom_id TEXT;
BEGIN
  -- Récupérer le custom_id depuis les métadonnées ou le générer
  v_custom_id := NEW.raw_user_meta_data->>'custom_id';
  
  -- Si pas de custom_id dans les métadonnées, en générer un
  IF v_custom_id IS NULL OR v_custom_id = '' THEN
    v_custom_id := upper(substring(md5(random()::text) from 1 for 3)) || 
                   lpad(floor(random() * 10000)::text, 4, '0');
  END IF;
  
  -- Insérer dans user_ids
  INSERT INTO public.user_ids (user_id, custom_id)
  VALUES (NEW.id, v_custom_id)
  ON CONFLICT (user_id) DO NOTHING;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Supprimer le trigger existant s'il existe
DROP TRIGGER IF EXISTS on_auth_user_id_created ON auth.users;

-- Créer le trigger pour créer l'ID utilisateur
CREATE TRIGGER on_auth_user_id_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user_id();