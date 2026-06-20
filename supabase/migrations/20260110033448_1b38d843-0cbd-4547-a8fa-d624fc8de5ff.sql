-- Fix mapping/consistency for standardized IDs across roles and keep user_ids.custom_id in sync with profiles.public_id

CREATE OR REPLACE FUNCTION public.auto_generate_profile_public_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
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
    WHEN 'ceo' THEN prefix := 'PDG';
    WHEN 'pdg' THEN prefix := 'PDG';
    WHEN 'syndicat' THEN prefix := 'SYD';
    WHEN 'taxi' THEN prefix := 'DRV';
    WHEN 'transitaire' THEN prefix := 'TRS';
    ELSE prefix := 'USR';
  END CASE;

  -- Créer le compteur s'il n'existe pas
  INSERT INTO public.id_counters (prefix, current_value, description)
  VALUES (prefix, 0, 'Auto-créé pour ' || COALESCE(NEW.role::text, 'client'))
  ON CONFLICT (prefix) DO NOTHING;

  -- Incrémenter et obtenir la nouvelle valeur de façon atomique
  UPDATE public.id_counters
  SET current_value = current_value + 1,
      updated_at = now()
  WHERE public.id_counters.prefix = prefix
  RETURNING current_value INTO next_val;

  NEW.public_id := prefix || LPAD(next_val::text, 4, '0');
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_profile_public_id_on_role_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  next_val int;
  expected_prefix text;
BEGIN
  IF OLD.role IS DISTINCT FROM NEW.role THEN
    CASE COALESCE(NEW.role, 'client')
      WHEN 'client' THEN expected_prefix := 'CLI';
      WHEN 'vendeur' THEN expected_prefix := 'VND';
      WHEN 'agent' THEN expected_prefix := 'AGT';
      WHEN 'livreur' THEN expected_prefix := 'DRV';
      WHEN 'admin' THEN expected_prefix := 'ADM';
      WHEN 'ceo' THEN expected_prefix := 'PDG';
      WHEN 'pdg' THEN expected_prefix := 'PDG';
      WHEN 'syndicat' THEN expected_prefix := 'SYD';
      WHEN 'taxi' THEN expected_prefix := 'DRV';
      WHEN 'transitaire' THEN expected_prefix := 'TRS';
      ELSE expected_prefix := 'USR';
    END CASE;

    -- Si l'ID actuel a déjà le bon préfixe, ne rien faire
    IF NEW.public_id IS NOT NULL AND NEW.public_id ~ ('^' || expected_prefix || '[0-9]{4}$') THEN
      RETURN NEW;
    END IF;

    INSERT INTO public.id_counters (prefix, current_value, description)
    VALUES (expected_prefix, 0, 'Auto-créé pour ' || COALESCE(NEW.role::text, 'client'))
    ON CONFLICT (prefix) DO NOTHING;

    UPDATE public.id_counters
    SET current_value = current_value + 1,
        updated_at = now()
    WHERE public.id_counters.prefix = expected_prefix
    RETURNING current_value INTO next_val;

    NEW.public_id := expected_prefix || LPAD(next_val::text, 4, '0');
  END IF;

  RETURN NEW;
END;
$$;

-- Fix: qualify column name to avoid "WHERE prefix = prefix" bug + add 'ceo' mapping
CREATE OR REPLACE FUNCTION public.generate_unique_public_id(user_role_param text DEFAULT 'client'::text)
RETURNS text
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  new_id text;
  pfx text;
  next_val int;
BEGIN
  CASE user_role_param
    WHEN 'client' THEN pfx := 'CLI';
    WHEN 'vendeur' THEN pfx := 'VND';
    WHEN 'agent' THEN pfx := 'AGT';
    WHEN 'livreur' THEN pfx := 'DRV';
    WHEN 'admin' THEN pfx := 'ADM';
    WHEN 'ceo' THEN pfx := 'PDG';
    WHEN 'pdg' THEN pfx := 'PDG';
    WHEN 'syndicat' THEN pfx := 'SYD';
    WHEN 'taxi' THEN pfx := 'DRV';
    WHEN 'transitaire' THEN pfx := 'TRS';
    ELSE pfx := 'USR';
  END CASE;

  INSERT INTO public.id_counters (prefix, current_value, description)
  VALUES (pfx, 0, 'Auto-créé pour ' || user_role_param)
  ON CONFLICT (prefix) DO NOTHING;

  UPDATE public.id_counters
  SET current_value = current_value + 1,
      updated_at = now()
  WHERE public.id_counters.prefix = pfx
  RETURNING current_value INTO next_val;

  new_id := pfx || LPAD(next_val::text, 4, '0');
  RETURN new_id;
END;
$$;

-- Keep trigger behavior consistent if it ever runs (should usually be bypassed by auto_generate_profile_public_id)
CREATE OR REPLACE FUNCTION public.auto_generate_standard_id_on_signup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_prefix VARCHAR(3);
  v_new_id TEXT;
BEGIN
  IF NEW.public_id IS NOT NULL AND NEW.public_id != '' THEN
    RETURN NEW;
  END IF;

  v_prefix := CASE
    WHEN NEW.role = 'vendeur' THEN 'VND'
    WHEN NEW.role IN ('livreur','taxi') THEN 'DRV'
    WHEN NEW.role = 'agent' THEN 'AGT'
    WHEN NEW.role = 'admin' THEN 'ADM'
    WHEN NEW.role IN ('ceo','pdg') THEN 'PDG'
    WHEN NEW.role = 'syndicat' THEN 'SYD'
    WHEN NEW.role = 'transitaire' THEN 'TRS'
    WHEN NEW.role = 'client' THEN 'CLI'
    ELSE 'USR'
  END;

  v_new_id := generate_sequential_id(v_prefix);
  NEW.public_id := v_new_id;
  RETURN NEW;
END;
$$;

-- Align helper to the standardized role prefixes
CREATE OR REPLACE FUNCTION public.get_prefix_for_role(p_role text)
RETURNS character varying
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN CASE
    WHEN p_role = 'client' THEN 'CLI'
    WHEN p_role = 'vendeur' THEN 'VND'
    WHEN p_role IN ('livreur', 'taxi') THEN 'DRV'
    WHEN p_role = 'agent' THEN 'AGT'
    WHEN p_role = 'syndicat' THEN 'SYD'
    WHEN p_role = 'transitaire' THEN 'TRS'
    WHEN p_role = 'admin' THEN 'ADM'
    WHEN p_role IN ('ceo','pdg') THEN 'PDG'
    ELSE 'USR'
  END;
END;
$$;

-- Ensure profile role change keeps user_ids.custom_id == profiles.public_id
CREATE OR REPLACE FUNCTION public.update_custom_id_on_role_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF OLD.role IS DISTINCT FROM NEW.role THEN
    UPDATE public.user_ids
    SET custom_id = NEW.public_id
    WHERE user_id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$;