-- ============================================================================
-- 🔒 FERMETURE DE LA FUITE D'ISOLATION DES PROFILS (Phase 2 / FIX 3)
-- Réf : docs/AUDIT_PROFILES_ACCESS.md
--
-- ⚠️⚠️  DÉPLOYER *UNIQUEMENT* APRÈS que FIX 1 (endpoints backend) ET FIX 2 (bascule
--       frontend) soient EN PRODUCTION. Sinon l'application casse (courses / transferts /
--       messagerie / écrans agent tomberaient en 403, ne voyant plus que le profil self).
--
-- Séquence de déploiement OBLIGATOIRE :
--   1. Backend : /api/v2/profiles/{:id/contact, display-names, resolve} déployés + REVOKE RPC.
--   2. Frontend : toutes les lectures tierces `from('profiles')` repointées vers ces endpoints
--      (garde-fou vitest : src/services/__tests__/profilesIsolation.guard.test.ts).
--   3. SEULEMENT ENSUITE : appliquer CETTE migration.
--
-- Effet : un utilisateur `authenticated` ne voit plus QUE son propre profil (policy self
-- `profiles_select`) + admin/PDG (policies dédiées). Toute lecture d'un profil tiers passe
-- par le backend (service_role) qui choisit des colonnes minimales.
--
-- NB : on NE ré-impose PAS le REVOKE colonne (migration 20260609120000) — il avait cassé le
-- login (20260609140000 l'a annulé). La protection vient de la RLS *ligne* (self-only) :
-- les seules lignes tierces atteignables par le client sont servies par le backend.
-- ============================================================================

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1) profiles : suppression de la policy PERMISSIVE `USING (true)` qui annulait (OR)
--    toutes les policies strictes. (Définie en 20260514000000, recréée en 20260520000000.)
-- ────────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Authenticated users can view basic profile info" ON public.profiles;

-- Policies CONSERVÉES (aucune ne doit rester permissive `true` en SELECT/ALL pour
-- authenticated/public — vérifié via l'audit §1C) :
--   ✅ profiles_select                    → USING (id = auth.uid())        (self)
--   ✅ admins_can_view_all_profiles       → self OR pdg_management OR jwt.role='admin'
--   ✅ pdg_select_all_profiles            → EXISTS(pdg_management …)
--   ✅ admins_and_pdg_can_view_vendors    → self OR EXISTS(pdg_management …)
--   ✅ profiles_insert / profiles_update  → self ; profiles_service_insert → service_role
--   ✅ trigger guard_profile_critical_fields (role/email/id non modifiables par authenticated)

-- ────────────────────────────────────────────────────────────────────────────
-- 2) RPC search_profiles_for_messaging : SECURITY DEFINER qui renvoyait email+phone via
--    JOIN auth.users et CONTOURNAIT le DROP ci-dessus. Repointée côté frontend vers
--    /api/v2/profiles/resolve. On révoque son exécution (anon/authenticated/public).
-- ────────────────────────────────────────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.search_profiles_for_messaging(TEXT, INT) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.search_profiles_for_messaging(TEXT, INT) FROM anon;
REVOKE EXECUTE ON FUNCTION public.search_profiles_for_messaging(TEXT, INT) FROM PUBLIC;
-- (Alternative : DROP FUNCTION public.search_profiles_for_messaging(TEXT, INT); — plus aucun
--  appelant après FIX 2. On se limite au REVOKE pour un rollback trivial.)

-- ────────────────────────────────────────────────────────────────────────────
-- 3) registered_motos : la policy `TO public` exposait owner_name / owner_phone / plate_number
--    à des utilisateurs ANONYMES (PII). On la restreint à `authenticated`. La page publique
--    d'un bureau (accès anon via access_token) doit passer par un endpoint backend dédié pour
--    afficher les motos sans PII (TODO backend — non bloquant pour la fermeture ici).
-- ────────────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Public can view registered_motos with valid bureau" ON public.registered_motos;
CREATE POLICY "Authenticated can view registered_motos with valid bureau"
ON public.registered_motos
FOR SELECT
TO authenticated
USING (
  bureau_id IN (
    SELECT id FROM public.bureaus WHERE access_token IS NOT NULL
  )
);

-- ────────────────────────────────────────────────────────────────────────────
-- 4) user_ids  → DÉCISION : LAISSÉ OUVERT (justifié). La table ne mappe que
--    user_id ↔ custom_id/public_id : des identifiants SEMI-PUBLICS, aucune PII (ni email, ni
--    téléphone, ni adresse). La policy actuelle est déjà `TO authenticated` (pas `public`) →
--    anon ne peut pas lire. La résolution CROSS-utilisateur (transfert/messagerie) est
--    désormais faite côté backend (service_role) ; le frontend n'utilise plus user_ids que pour
--    afficher un code (≈27 flux légitimes de type user_id→custom_id). Un scope self-only
--    casserait ces affichages sans gain de confidentialité (identifiants non sensibles).
--    → AUCUN changement ici. Surveillance d'énumération = rate-limit backend + monitoring.
--
-- 5) user_presence → DÉCISION : LAISSÉ OUVERT (justifié, cf. migration 20260617310000).
--    Statut « en ligne » partagé, faible sensibilité, PAS de PII (user_id, status, last_seen).
--    Écriture déjà scopée (`Users can update own presence`). → AUCUN changement ici.
-- ────────────────────────────────────────────────────────────────────────────

COMMIT;

-- ============================================================================
-- ROLLBACK (si régression après application) :
--   BEGIN;
--   CREATE POLICY "Authenticated users can view basic profile info" ON public.profiles
--     FOR SELECT TO authenticated USING (true);
--   GRANT EXECUTE ON FUNCTION public.search_profiles_for_messaging(TEXT, INT) TO authenticated;
--   DROP POLICY IF EXISTS "Authenticated can view registered_motos with valid bureau" ON public.registered_motos;
--   CREATE POLICY "Public can view registered_motos with valid bureau" ON public.registered_motos
--     FOR SELECT TO public USING (bureau_id IN (SELECT id FROM public.bureaus WHERE access_token IS NOT NULL));
--   COMMIT;
-- ============================================================================
