-- ============================================================================
-- ALIGNEMENT DES PRÉDICATS D'ACCÈS is_admin / is_admin_or_pdg — Option A (union)
-- ----------------------------------------------------------------------------
-- Problème : chaque fonction a 2 signatures qui calculaient des choses DIFFÉRENTES
--   • is_admin(uuid)        = profiles.role IN ('ceo','admin')      [INVOKER]
--   • is_admin()            = (aucune définition traçable, ~21 policies)
--   • is_admin_or_pdg(uuid) = pdg_management actif
--   • is_admin_or_pdg()     = profiles.role IN ('admin','pdg')
-- → selon la policy, un même utilisateur pouvait être admin ou pas (incohérence).
--
-- Correctif SANS réécrire les ~167 policies : on redéfinit les 2 signatures de
-- chaque fonction pour qu'elles partagent UNE règle canonique. La forme sans
-- argument délègue à la forme (uuid) appliquée à auth.uid().
--
-- Règle canonique (Option A = UNION → aucun accès actuel retiré) :
--   • is_admin(uid)        = profiles.role IN ('ceo','admin','super_admin')
--   • is_admin_or_pdg(uid) = profiles.role IN ('ceo','admin','pdg','super_admin')
--                            OR pdg_management actif (user_id=uid)
--
-- SECURITY DEFINER + search_path : indispensable pour lire profiles/pdg_management
-- SANS déclencher la RLS de ces tables (évite la récursion de policy). Prédicats
-- booléens en lecture seule → EXECUTE ouvert aux rôles qui évaluent les policies.
-- Idempotent (CREATE OR REPLACE, noms de params inchangés).
-- ============================================================================

-- ─────────────── is_admin ───────────────
-- (uuid) : source canonique. Passe INVOKER → DEFINER (cohérence + anti-récursion RLS).
CREATE OR REPLACE FUNCTION public.is_admin(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = _user_id
      AND role::text IN ('ceo', 'admin', 'super_admin')
  );
$$;

-- () : délègue à la forme (uuid) sur auth.uid() → même logique partout.
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_admin(auth.uid());
$$;

-- ─────────────── is_admin_or_pdg ───────────────
-- (uuid) : source canonique = UNION (profiles.role élargi OU pdg_management actif).
CREATE OR REPLACE FUNCTION public.is_admin_or_pdg(user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = $1
      AND p.role::text IN ('ceo', 'admin', 'pdg', 'super_admin')
  )
  OR EXISTS (
    SELECT 1 FROM public.pdg_management m
    WHERE m.user_id = $1
      AND m.is_active = true
  );
$$;

-- () : délègue à la forme (uuid) sur auth.uid().
CREATE OR REPLACE FUNCTION public.is_admin_or_pdg()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_admin_or_pdg(auth.uid());
$$;

-- ─────────────── EXECUTE (prédicats utilisés dans les policies) ───────────────
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION public.is_admin(uuid) TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION public.is_admin_or_pdg() TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION public.is_admin_or_pdg(uuid) TO authenticated, anon, service_role;

-- ─────────────── VÉRIFICATIONS (à contrôler après application) ───────────────
-- 1) Les 4 fonctions renvoient bien un booléen cohérent (remplace <UUID_PDG> et
--    <UUID_ADMIN> par de vrais ids pour tester) :
--    SELECT public.is_admin('<UUID_ADMIN>'), public.is_admin_or_pdg('<UUID_PDG>');
-- 2) Un compte NON privilégié doit renvoyer false partout.
