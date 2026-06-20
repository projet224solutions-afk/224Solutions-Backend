-- Corriger la fonction get_broadcast_target_users pour utiliser les rôles valides de l'enum
CREATE OR REPLACE FUNCTION get_broadcast_target_users(
  p_segment TEXT DEFAULT 'all',
  p_roles TEXT[] DEFAULT NULL,
  p_regions TEXT[] DEFAULT NULL,
  p_user_ids UUID[] DEFAULT NULL
)
RETURNS TABLE(
  user_id UUID,
  user_role TEXT,
  user_email TEXT,
  user_name TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    p.id as user_id,
    p.role::TEXT as user_role,
    p.email as user_email,
    COALESCE(p.full_name, p.first_name || ' ' || p.last_name, p.email) as user_name
  FROM profiles p
  WHERE
    -- Filtre par segment - Utiliser les rôles corrects de l'enum user_role
    CASE
      WHEN p_segment = 'all' THEN true
      WHEN p_segment = 'agents' THEN p.role::TEXT IN ('agent')
      WHEN p_segment = 'vendors' THEN p.role::TEXT IN ('vendeur')
      WHEN p_segment = 'clients' THEN p.role::TEXT IN ('client')
      WHEN p_segment = 'drivers' THEN p.role::TEXT IN ('livreur', 'taxi')
      WHEN p_segment = 'admins' THEN p.role::TEXT IN ('admin', 'pdg', 'ceo')
      WHEN p_segment = 'custom' THEN
        (array_length(p_roles, 1) IS NULL OR p.role::TEXT = ANY(p_roles))
      ELSE true
    END
    -- Filtre par régions (si spécifié)
    AND (array_length(p_regions, 1) IS NULL OR p.region = ANY(p_regions))
    -- Filtre par IDs spécifiques (si spécifié)
    AND (array_length(p_user_ids, 1) IS NULL OR p.id = ANY(p_user_ids))
    -- Utilisateur actif
    AND COALESCE(p.is_active, true) = true;
END;
$$;