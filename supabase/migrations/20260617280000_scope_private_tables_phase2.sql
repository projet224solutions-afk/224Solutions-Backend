-- ============================================================================
-- 🔒 ISOLATION DES DONNÉES — PALIER 2 (financier / perso).
--
-- Suite de 20260617270000 (palier 1 critique). Mêmes principes : on supprime les
-- policies ENTIÈREMENT ouvertes (`USING(true)`/`WITH CHECK(true)` permissives) sur
-- des tables privées, en s'appuyant sur la policy déjà scopée quand elle existe,
-- sinon en recréant une policy correcte (propriétaire / PDG / parties).
--
-- Vérifié frontend (grep `from('table')`) AVANT chaque décision :
--   • DROP redondant (une policy scopée existe déjà) : agent_permissions (anon),
--     dispute_messages, payment_methods, vendor_transactions.
--   • LOCK backend-only (0 lecture frontend) : dispute_actions,
--     service_subscription_payments, syndicate_worker_permissions, vendor_analytics.
--   • REMPLACE l'ouverte « PDG » (en fait ouverte à tous) par is_admin_or_pdg :
--     fraud_detection_logs, invoices, quotes.
--   • SCOPE par colonne/jointure : escrow_action_logs, wallet_logs, payment_links,
--     suspicious_activities.
--
-- ⛔ TENU (à confirmer) : payment_schedules (lecture front via jointure orders ;
--    policy scopée `users_own_payment_schedules` à valider avant de retirer l'ouverte).
--
-- Idempotent (DROP IF EXISTS + recréation), non destructif des policies scopées.
-- ============================================================================

-- ── ÉTAPE 1 : supprimer toutes les policies entièrement ouvertes des tables visées ──
DO $$
DECLARE
  r record;
  targets text[] := ARRAY[
    'agent_permissions','dispute_actions','dispute_messages','escrow_action_logs',
    'fraud_detection_logs','invoices','payment_links','payment_methods','quotes',
    'service_subscription_payments','suspicious_activities','syndicate_worker_permissions',
    'vendor_analytics','vendor_transactions','wallet_logs'
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

-- ── ÉTAPE 2 : remplacements « PDG » (les dashboards PDG doivent tout voir) ────

-- fraud_detection_logs : PDG gère tout ; la policy scopée users_view_own_fraud_logs reste.
DROP POLICY IF EXISTS "pdg_manage_fraud_logs" ON public.fraud_detection_logs;
CREATE POLICY "pdg_manage_fraud_logs" ON public.fraud_detection_logs
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

-- invoices : PDG voit toutes les factures (les policies vendeur scopées restent).
DROP POLICY IF EXISTS "pdg_view_all_invoices" ON public.invoices;
CREATE POLICY "pdg_view_all_invoices" ON public.invoices
  FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())));

-- quotes : PDG voit tous les devis (les policies vendeur scopées restent).
DROP POLICY IF EXISTS "pdg_view_all_quotes" ON public.quotes;
CREATE POLICY "pdg_view_all_quotes" ON public.quotes
  FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())));

-- ── ÉTAPE 3 : scopages par colonne / jointure ────────────────────────────────

-- escrow_action_logs : lecture = parties de l'escrow + PDG (fermeture de la fuite
-- d'audit) ; insert conservé pour le journal (non-bloquant) mais on empêche
-- d'usurper le performed_by d'un autre compte.
DROP POLICY IF EXISTS "escrow_logs_parties_select" ON public.escrow_action_logs;
CREATE POLICY "escrow_logs_parties_select" ON public.escrow_action_logs
  FOR SELECT TO authenticated
  USING (
    public.is_admin_or_pdg((select auth.uid()))
    OR escrow_id IN (
      SELECT id FROM public.escrows
      WHERE seller_id = (select auth.uid()) OR buyer_id = (select auth.uid())
    )
  );
DROP POLICY IF EXISTS "escrow_logs_actor_insert" ON public.escrow_action_logs;
CREATE POLICY "escrow_logs_actor_insert" ON public.escrow_action_logs
  FOR INSERT TO authenticated
  WITH CHECK (performed_by IS NULL OR performed_by = (select auth.uid()));

-- wallet_logs : lecture = propriétaire + PDG ; insert conservé (journal, non-bloquant)
-- sans pouvoir usurper le user_id d'autrui. UPDATE/DELETE = backend (service_role).
DROP POLICY IF EXISTS "wallet_logs_owner_pdg_select" ON public.wallet_logs;
CREATE POLICY "wallet_logs_owner_pdg_select" ON public.wallet_logs
  FOR SELECT TO authenticated
  USING (user_id = (select auth.uid()) OR public.is_admin_or_pdg((select auth.uid())));
DROP POLICY IF EXISTS "wallet_logs_owner_insert" ON public.wallet_logs;
CREATE POLICY "wallet_logs_owner_insert" ON public.wallet_logs
  FOR INSERT TO authenticated
  WITH CHECK (user_id IS NULL OR user_id = (select auth.uid()));

-- payment_links : la policy scopée « Owners can manage » (owner_user_id) couvre le
-- propriétaire (lecteur principal = owner_user_id). On rétablit la vue client scopée.
DROP POLICY IF EXISTS "payment_links_client_select" ON public.payment_links;
CREATE POLICY "payment_links_client_select" ON public.payment_links
  FOR SELECT TO authenticated
  USING (
    client_id = (select auth.uid())
    OR owner_user_id = (select auth.uid())
    OR public.is_admin_or_pdg((select auth.uid()))
  );

-- suspicious_activities : le vendeur voit les siennes (front filtre vendor_id = user.id) + PDG.
DROP POLICY IF EXISTS "suspicious_owner_pdg_select" ON public.suspicious_activities;
CREATE POLICY "suspicious_owner_pdg_select" ON public.suspicious_activities
  FOR SELECT TO authenticated
  USING (vendor_id = (select auth.uid()) OR public.is_admin_or_pdg((select auth.uid())));

-- ── ÉTAPE 4 : tables verrouillées backend-only (0 lecture frontend) ──────────
-- dispute_actions, service_subscription_payments, syndicate_worker_permissions,
-- vendor_analytics : leurs policies ouvertes ont été supprimées (étape 1), aucune
-- policy authenticated recréée → accès direct bloqué, backend (service_role) seul.

SELECT 'Palier 2 OK : 4 PDG-scoped (fraud/invoices/quotes), escrow_action_logs/wallet_logs/payment_links/suspicious_activities scopés, 4 tables verrouillées backend-only, opens redondantes retirées. payment_schedules tenu.' AS status;
