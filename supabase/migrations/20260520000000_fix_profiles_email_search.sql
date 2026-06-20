-- ============================================================
-- FIX: Recherche utilisateurs par email dans le système de messagerie
-- Problèmes résolus :
--   1. profiles.email NULL pour anciens utilisateurs → backfill depuis auth.users
--   2. Politique RLS manquante après DROP de users_can_search_profiles_for_messaging
--   3. Index manquant sur profiles.email pour performances
-- ============================================================

-- 1. Backfill des emails manquants depuis auth.users
UPDATE public.profiles p
SET email = u.email
FROM auth.users u
WHERE p.id = u.id
  AND u.email IS NOT NULL
  AND (p.email IS NULL OR p.email = '');

-- 2. Recréer la politique de recherche (supprimée par migration 20260401)
DROP POLICY IF EXISTS "users_can_search_profiles_for_messaging" ON public.profiles;
DROP POLICY IF EXISTS "Authenticated users can view basic profile info" ON public.profiles;

CREATE POLICY "Authenticated users can view basic profile info"
ON public.profiles
FOR SELECT
TO authenticated
USING (true);

-- 3. Index sur email pour accélérer les recherches ilike
CREATE INDEX IF NOT EXISTS idx_profiles_email_lower
ON public.profiles (lower(email));

-- 4. Index sur public_id pour accélérer les recherches par ID
CREATE INDEX IF NOT EXISTS idx_profiles_public_id
ON public.profiles (public_id);

-- 5. Fonction RPC sécurisée pour rechercher des profils (fallback auth.users)
CREATE OR REPLACE FUNCTION public.search_profiles_for_messaging(
  search_term TEXT,
  max_results INT DEFAULT 10
)
RETURNS TABLE (
  id UUID,
  first_name TEXT,
  last_name TEXT,
  email TEXT,
  avatar_url TEXT,
  public_id TEXT,
  role TEXT,
  phone TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  -- Recherche dans profiles
  RETURN QUERY
  SELECT DISTINCT
    p.id,
    p.first_name,
    p.last_name,
    COALESCE(p.email, u.email) AS email,
    p.avatar_url,
    p.public_id,
    p.role::TEXT,
    p.phone
  FROM public.profiles p
  LEFT JOIN auth.users u ON u.id = p.id
  WHERE
    lower(COALESCE(p.email, u.email, '')) ILIKE '%' || lower(search_term) || '%'
    OR lower(COALESCE(p.first_name, '') || ' ' || COALESCE(p.last_name, '')) ILIKE '%' || lower(search_term) || '%'
    OR lower(COALESCE(p.public_id, '')) ILIKE '%' || lower(search_term) || '%'
    OR lower(COALESCE(p.phone, '')) ILIKE '%' || lower(search_term) || '%'
  LIMIT max_results;
END;
$$;

-- Donner accès à la fonction aux utilisateurs authentifiés
GRANT EXECUTE ON FUNCTION public.search_profiles_for_messaging(TEXT, INT) TO authenticated;
