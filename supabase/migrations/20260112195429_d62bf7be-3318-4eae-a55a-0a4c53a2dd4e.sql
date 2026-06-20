-- Mettre à jour la fonction handle_new_user pour gérer correctement les inscriptions
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  user_role_value user_role;
  user_role_text text;
  raw_role text;
  account_type_raw text;
BEGIN
  -- Récupérer le rôle depuis plusieurs sources possibles
  raw_role := (NEW.raw_user_meta_data::jsonb)->>'role';
  account_type_raw := (NEW.raw_user_meta_data::jsonb)->>'account_type';
  
  -- Mapper account_type vers role si nécessaire
  IF raw_role IS NOT NULL AND raw_role != '' THEN
    user_role_text := raw_role;
  ELSIF account_type_raw IS NOT NULL AND account_type_raw != '' THEN
    -- Mapper les account_types vers les rôles
    CASE account_type_raw
      WHEN 'marchand' THEN user_role_text := 'vendeur';
      WHEN 'merchant' THEN user_role_text := 'vendeur';
      WHEN 'livreur' THEN user_role_text := 'livreur';
      WHEN 'driver' THEN user_role_text := 'livreur';
      WHEN 'taxi_moto' THEN user_role_text := 'taxi';
      WHEN 'taxi-moto' THEN user_role_text := 'taxi';
      WHEN 'transitaire' THEN user_role_text := 'transitaire';
      WHEN 'client' THEN user_role_text := 'client';
      ELSE user_role_text := 'client';
    END CASE;
  ELSE
    user_role_text := 'client';
  END IF;

  -- Convertir en type enum avec fallback
  BEGIN
    user_role_value := user_role_text::user_role;
  EXCEPTION WHEN OTHERS THEN
    user_role_text := 'client';
    user_role_value := 'client'::user_role;
  END;

  -- Insérer le profil
  INSERT INTO public.profiles (id, email, full_name, first_name, last_name, public_id, role, created_at, updated_at)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(
      (NEW.raw_user_meta_data::jsonb)->>'full_name', 
      (NEW.raw_user_meta_data::jsonb)->>'name',
      NULLIF(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'first_name', '') || ' ' || COALESCE((NEW.raw_user_meta_data::jsonb)->>'last_name', '')), ''),
      split_part(NEW.email, '@', 1)
    ),
    NULLIF(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'first_name', '')), ''),
    NULLIF(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'last_name', '')), ''),
    public.generate_unique_public_id(user_role_text),
    user_role_value,
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO UPDATE SET
    email = EXCLUDED.email,
    full_name = COALESCE(profiles.full_name, EXCLUDED.full_name),
    first_name = COALESCE(profiles.first_name, EXCLUDED.first_name),
    last_name = COALESCE(profiles.last_name, EXCLUDED.last_name),
    updated_at = NOW();
  
  RETURN NEW;
END;
$function$;