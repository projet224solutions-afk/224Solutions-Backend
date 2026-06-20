-- ============================================================================
-- 🔒 ISOLATION DES DONNÉES — fermeture des fuites CRITIQUES « USING(true) ».
--
-- Audit (2026-06-17) : plusieurs tables PRIVÉES avaient une policy permissive
-- `USING(true)` / `WITH CHECK(true)` pour {authenticated} → tout compte connecté
-- lisait/écrivait les lignes de TOUS les autres comptes.
--
-- 🔴 LE PLUS GRAVE — pdg_management : is_admin_or_pdg(uuid) = EXISTS(pdg_management
--    WHERE user_id=$1 AND is_active). Avec l'écriture ouverte, n'importe quel
--    compte pouvait s'auto-insérer (is_active=true) → DEVENIR PDG → admin total.
--    On verrouille l'écriture aux PDG existants (+ backend service_role, BYPASSRLS).
--    Les lectures frontend filtrent toutes par user_id = soi → aucune casse.
--    NB: le provisionnement du 1er PDG / des agents doit passer par le BACKEND
--    (service_role) ; l'auto-création frontend pour un non-PDG est désormais bloquée
--    (c'était précisément le trou).
--
-- ⛔ NON TRAITÉ ICI (casserait le front — phase dédiée) :
--    order_items (12+ lectures front, pas de user_id direct : propriété via
--    order_id→orders / product→vendor) → scopage par jointure à concevoir.
--
-- Idempotent (DROP IF EXISTS + recréation) et non destructif des policies déjà
-- correctement scopées (on ne supprime QUE les policies entièrement ouvertes).
-- ============================================================================

-- ── ÉTAPE 1 : supprimer les policies entièrement ouvertes sur les tables visées ──
-- (permissives dont USING et WITH CHECK valent NULL ou 'true' — donc sans aucune
--  restriction). On préserve toute policy déjà scopée.
DO $$
DECLARE
  r record;
  targets text[] := ARRAY[
    'pdg_management','mfa_verifications','health_patient_records',
    'health_consultations','escrows','wallet_transfers'
  ];
BEGIN
  FOR r IN
    SELECT c.relname AS tbl, p.polname
    FROM pg_policy p
    JOIN pg_class c ON c.oid = p.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = ANY(targets)
      AND p.polpermissive
      AND (p.polqual IS NULL
           OR btrim(lower(pg_get_expr(p.polqual, p.polrelid))) = 'true')
      AND (p.polwithcheck IS NULL
           OR btrim(lower(pg_get_expr(p.polwithcheck, p.polrelid))) = 'true')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.polname, r.tbl);
    RAISE NOTICE 'Policy ouverte supprimée : % sur %', r.polname, r.tbl;
  END LOOP;
END $$;

-- ── ÉTAPE 2 : policies scopées ──────────────────────────────────────────────

-- pdg_management : lecture = sa propre ligne OU PDG ; écriture = PDG existant seul.
DROP POLICY IF EXISTS "pdg_select_own_or_admin" ON public.pdg_management;
CREATE POLICY "pdg_select_own_or_admin" ON public.pdg_management
  FOR SELECT TO authenticated
  USING (user_id = (select auth.uid()) OR public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "pdg_insert_admin_only" ON public.pdg_management;
CREATE POLICY "pdg_insert_admin_only" ON public.pdg_management
  FOR INSERT TO authenticated
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "pdg_update_admin_only" ON public.pdg_management;
CREATE POLICY "pdg_update_admin_only" ON public.pdg_management
  FOR UPDATE TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "pdg_delete_admin_only" ON public.pdg_management;
CREATE POLICY "pdg_delete_admin_only" ON public.pdg_management
  FOR DELETE TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())));

-- mfa_verifications : strictement le propriétaire (backend = service_role BYPASSRLS).
DROP POLICY IF EXISTS "mfa_owner_all" ON public.mfa_verifications;
CREATE POLICY "mfa_owner_all" ON public.mfa_verifications
  FOR ALL TO authenticated
  USING (user_id = (select auth.uid()))
  WITH CHECK (user_id = (select auth.uid()));

-- escrows : lecture par les parties (acheteur/vendeur) + PDG ; écriture backend-only.
DROP POLICY IF EXISTS "escrows_parties_select" ON public.escrows;
CREATE POLICY "escrows_parties_select" ON public.escrows
  FOR SELECT TO authenticated
  USING (
    seller_id = (select auth.uid())
    OR buyer_id = (select auth.uid())
    OR public.is_admin_or_pdg((select auth.uid()))
  );

-- wallet_transfers : lecture par émetteur/destinataire + PDG ; écriture backend-only.
DROP POLICY IF EXISTS "wallet_transfers_parties_select" ON public.wallet_transfers;
CREATE POLICY "wallet_transfers_parties_select" ON public.wallet_transfers
  FOR SELECT TO authenticated
  USING (
    sender_id = (select auth.uid())
    OR receiver_id = (select auth.uid())
    OR public.is_admin_or_pdg((select auth.uid()))
  );

-- health_patient_records & health_consultations : DONNÉES MÉDICALES → backend-only.
-- Les policies ouvertes ont été supprimées (étape 1) ; on ne recrée AUCUNE policy
-- authenticated → RLS active sans policy = accès direct anon/authenticated bloqué,
-- seul le backend (service_role, BYPASSRLS) y accède, conformément à la règle
-- « tout en backend » et à la stricte confidentialité médicale. Un accès patient/
-- soignant scopé pourra être ajouté plus tard si une interface front en a besoin.

SELECT 'OK : pdg_management (escalade fermée), mfa_verifications, escrows, wallet_transfers scopés ; health_* verrouillés backend-only. order_items tenu (phase dédiée).' AS status;
