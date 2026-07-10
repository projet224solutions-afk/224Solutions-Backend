-- ============================================================================
-- 🔒 VERROUILLAGE de la chaîne de Surveillance Plateforme
-- ----------------------------------------------------------------------------
-- Banc d'essai du 04/07/2026 (rôles anon + utilisateur lambda) — 2 trous RÉELS :
--
--   A) Les RPC de détection (escrow/dispute/subscription/transfer/commission/
--      order/wallet/pos_monitor_report, wallet_provenance_report,
--      money_integrity_report) étaient EXÉCUTABLES par anon ET authenticated
--      → n'importe qui pouvait lire les compteurs internes de la plateforme.
--      Ces RPC sont SECURITY DEFINER : exposées, elles bypassent la RLS.
--
--   B) system_alerts : un utilisateur lambda pouvait INSÉRER de fausses alertes,
--      MODIFIER le statut d'alertes réelles (masquer/ré-ouvrir) et les SUPPRIMER
--      (policies d'écriture basées sur auth.users.raw_user_meta_data->>'role',
--      jamais peuplé, + une policy permissive résiduelle). Un attaquant pouvait
--      donc masquer les vraies alertes de sécurité ou noyer le panneau.
--
-- CORRECTIF (le panneau PDG lit TOUT via le backend en service_role → aucun
-- impact fonctionnel) :
--   1) REVOKE EXECUTE de toutes les RPC de surveillance depuis PUBLIC/anon/
--      authenticated → service_role uniquement (bloc dynamique = couvre les
--      surcharges éventuelles).
--   2) system_alerts : toutes les policies remises à plat → SELECT réservé
--      admin/PDG (pour le realtime du panneau), AUCUNE écriture pour authenticated
--      (service_role écrit via BYPASSRLS). REVOKE des privilèges de table directs.
--
-- Non destructif (aucune donnée touchée), rejouable.
-- ============================================================================

-- 1) ── RPC de surveillance : service_role UNIQUEMENT ────────────────────────
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND (
        p.proname LIKE '%\_monitor\_report' ESCAPE '\'
        OR p.proname IN (
          'wallet_provenance_report',
          'money_integrity_report',
          'auto_reconcile_monitor_cases',
          'aml_wallet_overview'
        )
      )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', r.sig);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', r.sig);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.sig);
  END LOOP;
END $$;

-- 2) ── system_alerts : remise à plat des policies ──────────────────────────
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT policyname FROM pg_policies
           WHERE schemaname = 'public' AND tablename = 'system_alerts'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.system_alerts', r.policyname);
  END LOOP;
END $$;

ALTER TABLE public.system_alerts ENABLE ROW LEVEL SECURITY;

-- SELECT réservé admin/PDG : indispensable au realtime du panneau (Supabase
-- Realtime applique la RLS SELECT). Un utilisateur lambda ne voit RIEN.
CREATE POLICY system_alerts_admin_read ON public.system_alerts
  FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg(auth.uid()));

-- AUCUNE policy INSERT/UPDATE/DELETE → toute écriture par un rôle applicatif est
-- refusée. Seul le backend (service_role, BYPASSRLS) écrit les alertes.

-- Ceinture + bretelles : retirer les privilèges de table directs aux rôles publics.
REVOKE INSERT, UPDATE, DELETE ON public.system_alerts FROM anon, authenticated;

-- 3) ── Vérification ─────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND (p.proname LIKE '%\_monitor\_report' ESCAPE '\'
       OR p.proname IN ('wallet_provenance_report','money_integrity_report','auto_reconcile_monitor_cases','aml_wallet_overview'))
     AND (has_function_privilege('anon', p.oid, 'EXECUTE')
       OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))
  ) AS rpc_encore_exposees,
  (SELECT count(*) FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'system_alerts' AND cmd <> 'SELECT'
  ) AS policies_ecriture_restantes,
  (SELECT string_agg(policyname, ', ') FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'system_alerts'
  ) AS policies_system_alerts;
