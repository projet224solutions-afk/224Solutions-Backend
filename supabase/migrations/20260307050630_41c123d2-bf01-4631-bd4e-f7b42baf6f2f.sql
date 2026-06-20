-- 1. Mettre à jour la fonction generate_unique_public_id pour supporter 'prestataire', 'bureau', 'vendor_agent', 'driver'
CREATE OR REPLACE FUNCTION public.generate_unique_public_id(user_role_param text)
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
    WHEN 'driver' THEN role_prefix := 'DRV';
    WHEN 'transitaire' THEN role_prefix := 'TRS';
    WHEN 'prestataire' THEN role_prefix := 'PST';
    WHEN 'bureau' THEN role_prefix := 'BST';
    WHEN 'vendor_agent' THEN role_prefix := 'VAG';
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