-- Supprimer les fonctions existantes d'abord
DROP FUNCTION IF EXISTS public.generate_unique_public_id(text);
DROP FUNCTION IF EXISTS public.generate_unique_public_id(text, text);

-- Corriger auto_generate_profile_public_id
CREATE OR REPLACE FUNCTION public.auto_generate_profile_public_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  role_prefix text;
  next_val int;
BEGIN
  IF NEW.public_id IS NOT NULL AND NEW.public_id ~ '^[A-Z]{3}[0-9]{4}$' THEN
    RETURN NEW;
  END IF;

  CASE COALESCE(NEW.role::text, 'client')
    WHEN 'client' THEN role_prefix := 'CLI';
    WHEN 'vendeur' THEN role_prefix := 'VND';
    WHEN 'agent' THEN role_prefix := 'AGT';
    WHEN 'livreur' THEN role_prefix := 'DRV';
    WHEN 'admin' THEN role_prefix := 'ADM';
    WHEN 'ceo' THEN role_prefix := 'PDG';
    WHEN 'pdg' THEN role_prefix := 'PDG';
    WHEN 'syndicat' THEN role_prefix := 'SYD';
    WHEN 'taxi' THEN role_prefix := 'DRV';
    WHEN 'transitaire' THEN role_prefix := 'TRS';
    ELSE role_prefix := 'USR';
  END CASE;

  INSERT INTO public.id_counters (prefix, current_value, description)
  VALUES (role_prefix, 0, 'Auto-créé pour ' || COALESCE(NEW.role::text, 'client'))
  ON CONFLICT (prefix) DO NOTHING;

  UPDATE public.id_counters AS ic
  SET current_value = ic.current_value + 1, updated_at = now()
  WHERE ic.prefix = role_prefix
  RETURNING ic.current_value INTO next_val;

  NEW.public_id := role_prefix || LPAD(next_val::text, 4, '0');
  RETURN NEW;
END;
$$;

-- Recréer generate_unique_public_id
CREATE FUNCTION public.generate_unique_public_id(user_role_param text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  new_id text;
  role_prefix text;
  next_val int;
BEGIN
  CASE user_role_param
    WHEN 'client' THEN role_prefix := 'CLI';
    WHEN 'vendeur' THEN role_prefix := 'VND';
    WHEN 'agent' THEN role_prefix := 'AGT';
    WHEN 'livreur' THEN role_prefix := 'DRV';
    WHEN 'admin' THEN role_prefix := 'ADM';
    WHEN 'ceo' THEN role_prefix := 'PDG';
    WHEN 'pdg' THEN role_prefix := 'PDG';
    WHEN 'syndicat' THEN role_prefix := 'SYD';
    WHEN 'taxi' THEN role_prefix := 'DRV';
    WHEN 'transitaire' THEN role_prefix := 'TRS';
    ELSE role_prefix := 'USR';
  END CASE;

  INSERT INTO public.id_counters (prefix, current_value, description)
  VALUES (role_prefix, 0, 'Auto-créé pour ' || user_role_param)
  ON CONFLICT (prefix) DO NOTHING;

  UPDATE public.id_counters AS ic
  SET current_value = ic.current_value + 1, updated_at = now()
  WHERE ic.prefix = role_prefix
  RETURNING ic.current_value INTO next_val;

  new_id := role_prefix || LPAD(next_val::text, 4, '0');
  RETURN new_id;
END;
$$;