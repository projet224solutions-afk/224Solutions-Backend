-- ============================================================================
-- DÉTECTION TÉLÉPHONE ROBUSTE (tracking taxi/livreur)
-- ----------------------------------------------------------------------------
-- Les téléphones sont stockés dans des formats incohérents (avec/sans espace,
-- avec/sans indicatif : '+224 622306459', '+224622306459', '622306459'...).
-- La recherche par égalité exacte échouait souvent.
--
-- Solution : comparer les 9 DERNIERS CHIFFRES (numéro local), en ignorant
-- espaces, '+' et indicatif. Idempotent et sûr.
-- ============================================================================

-- Index sur le numéro normalisé (9 derniers chiffres) pour la performance à l'échelle
CREATE INDEX IF NOT EXISTS idx_profiles_phone_norm9
  ON public.profiles (right(regexp_replace(coalesce(phone, ''), '[^0-9]', '', 'g'), 9));

-- Résout un user_id à partir d'un numéro saisi sous n'importe quel format
CREATE OR REPLACE FUNCTION public.resolve_user_id_by_phone(p_phone text)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id
  FROM public.profiles
  WHERE length(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g')) >= 8
    AND right(regexp_replace(coalesce(phone, ''),   '[^0-9]', '', 'g'), 9) <> ''
    AND right(regexp_replace(coalesce(phone, ''),   '[^0-9]', '', 'g'), 9)
      = right(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), 9)
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_user_id_by_phone(text) TO authenticated, service_role, anon;
