-- ============================================================================
-- 🔒 ISOLATION — PALIER 3c : ARGENT / WALLET.
--
-- Objectif d'audit = LECTURE isolée (chaque compte ne voit que ses données).
-- Beaucoup de tables ont DÉJÀ un SELECT scopé (lecture OK) + un INSERT ouvert :
-- l'INSERT ouvert est une question d'intégrité d'écriture (risque de casse si
-- restreint à tort) → on ne le touche QUE quand c'est sûr (redondant / backend).
--
-- FUITES DE LECTURE corrigées : expense_analytics, expense_receipts, debt_payments,
--   global_ids, platform_revenue, wallet_payment_methods, wallet_idempotency_keys.
-- ÉCRITURES durcies (sûres) : p2p_transactions / revenus_pdg / transaction_audit_log /
--   wallet_suspicious_activities (INSERT ouverts retirés ; lecture déjà scopée ;
--   écriture réelle = backend service_role), bureau_transactions / bureau_wallets
--   (INSERT ouvert → restreint au propriétaire du bureau).
--
-- ⚠️ NON TRAITÉ ICI (à part) :
--   • subscriptions : EXPLOIT = un compte peut s'auto-insérer un abonnement gratuit
--     (price_paid_gnf=0, status=active) → premium sans payer. La lecture est déjà
--     isolée (user_id=self + PDG). Le correctif = passer la CRÉATION d'abonnement par
--     un RPC backend (vérif paiement) — changement fonctionnel, pas une simple RLS.
--   • transactions : lecture déjà scopée ; INSERT laissé (flux POS PaymentProcessor).
--   • card_transactions / conversion_logs / financial_transactions : lecture déjà
--     scopée ; INSERT laissé (faible risque).
--   • wallet_fees, plan_price_history : CONFIG (barème/prix), pas de données par compte.
--
-- Idempotent. Conserve les policies service_role et scopées existantes.
-- ============================================================================

-- ── expense_analytics : retirer le SELECT ouvert (2 policies scopées restent) ─
DROP POLICY IF EXISTS "Vendors can view their analytics" ON public.expense_analytics;

-- ── expense_receipts : aucune scopée + 0 lecture frontend → backend-only ─────
DROP POLICY IF EXISTS "Vendors can manage receipts for their expenses" ON public.expense_receipts;
DROP POLICY IF EXISTS "authenticated_view_expense_receipts" ON public.expense_receipts;

-- ── debt_payments : propriétaire de la dette (vendeur) + payeur/enregistreur + PDG ─
DROP POLICY IF EXISTS "Users can view payments for their debts" ON public.debt_payments;
DROP POLICY IF EXISTS "debt_payments_scoped_select" ON public.debt_payments;
CREATE POLICY "debt_payments_scoped_select" ON public.debt_payments
  FOR SELECT TO authenticated
  USING (
    paid_by = (select auth.uid())
    OR recorded_by = (select auth.uid())
    OR public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (
      SELECT 1 FROM public.debts d
      JOIN public.vendors v ON v.id = d.vendor_id
      WHERE d.id = debt_payments.debt_id AND v.user_id = (select auth.uid())
    )
  );
DROP POLICY IF EXISTS "Vendors can create payments" ON public.debt_payments;
DROP POLICY IF EXISTS "debt_payments_scoped_insert" ON public.debt_payments;
CREATE POLICY "debt_payments_scoped_insert" ON public.debt_payments
  FOR INSERT TO authenticated
  WITH CHECK (
    recorded_by = (select auth.uid())
    OR EXISTS (
      SELECT 1 FROM public.debts d
      JOIN public.vendors v ON v.id = d.vendor_id
      WHERE d.id = debt_payments.debt_id AND v.user_id = (select auth.uid())
    )
  );

-- ── global_ids : la policy « PDG » était ouverte à tous → vrai contrôle PDG ───
DROP POLICY IF EXISTS "PDG can manage global_ids" ON public.global_ids;
CREATE POLICY "global_ids_admin_pdg_manage" ON public.global_ids
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

-- ── platform_revenue : lecture = admin/PDG ; écriture = backend (system) ─────
DROP POLICY IF EXISTS "Admins can view platform revenue" ON public.platform_revenue;
CREATE POLICY "platform_revenue_admin_select" ON public.platform_revenue
  FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())));
DROP POLICY IF EXISTS "System can insert platform revenue" ON public.platform_revenue;
-- (insert = backend service_role uniquement, pas de policy authenticated)

-- ── wallet_payment_methods : account_number sensible, 0 usage frontend, et la FK
-- wallet_id(uuid) ↔ wallets.id(bigint) est incohérente (jointure impossible) →
-- backend-only (les écritures/lectures passent par le backend service_role).
DROP POLICY IF EXISTS "payment_methods_select" ON public.wallet_payment_methods;
DROP POLICY IF EXISTS "payment_methods_insert" ON public.wallet_payment_methods;
DROP POLICY IF EXISTS "payment_methods_update" ON public.wallet_payment_methods;
DROP POLICY IF EXISTS "payment_methods_delete" ON public.wallet_payment_methods;
-- (payment_methods_service / service_role conservée)

-- ── wallet_idempotency_keys : géré par les RPC wallet → backend-only ─────────
DROP POLICY IF EXISTS "user_own_idempotency" ON public.wallet_idempotency_keys;

-- ── Écritures durcies (lecture déjà scopée ; écriture réelle = backend) ──────
-- p2p_transactions : INSERT ouvert redondant (la policy ALL « users_own » impose déjà
-- WITH CHECK sender_id = auth.uid()).
DROP POLICY IF EXISTS "Users can create transactions" ON public.p2p_transactions;

-- revenus_pdg : INSERT ouvert retiré (backend service_role + la policy ALL self).
DROP POLICY IF EXISTS "System can insert revenus_pdg" ON public.revenus_pdg;

-- transaction_audit_log : journal écrit par le backend → INSERT ouvert retiré.
DROP POLICY IF EXISTS "System can insert audit logs" ON public.transaction_audit_log;

-- wallet_suspicious_activities : détection backend → INSERT ouverts retirés (SELECT scopé reste).
DROP POLICY IF EXISTS "Enable insert for authenticated users only" ON public.wallet_suspicious_activities;
DROP POLICY IF EXISTS "Enable insert for users based on user_id" ON public.wallet_suspicious_activities;

-- bureau_transactions / bureau_wallets : INSERT ouvert → restreint au propriétaire
-- du bureau (la lecture est déjà scopée ; le PDG garde sa policy ALL).
DROP POLICY IF EXISTS "Allow authenticated users to insert bureau_transactions" ON public.bureau_transactions;
CREATE POLICY "bureau_transactions_owner_insert" ON public.bureau_transactions
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.bureaus b
                      WHERE b.id = bureau_transactions.bureau_id AND b.user_id = (select auth.uid())));

DROP POLICY IF EXISTS "Allow authenticated to insert bureau_wallets" ON public.bureau_wallets;
CREATE POLICY "bureau_wallets_owner_insert" ON public.bureau_wallets
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.bureaus b
                      WHERE b.id = bureau_wallets.bureau_id AND b.user_id = (select auth.uid())));

SELECT 'Palier 3c OK : fuites lecture fermées (expense_analytics/receipts, debt_payments, global_ids, platform_revenue, wallet_payment_methods, wallet_idempotency_keys) + écritures durcies (p2p/revenus_pdg/audit_log/suspicious/bureau). subscriptions EXPLOIT signalé (→ RPC backend). transactions/card/financial/conversion : lecture déjà scopée, INSERT laissé.' AS status;
