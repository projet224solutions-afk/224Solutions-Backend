-- ============================================================================
-- 🏦 BASELINE de l'invariant du coffre — neutralise l'écart pré-coffre (héritage)
-- ----------------------------------------------------------------------------
-- Le contrôle treasury_balance_vs_ledger comparait le solde du coffre à la somme des
-- mouvements TRACÉS. Au démarrage, le coffre avait déjà un solde issu de voies antérieures
-- (escrow, régularisations) → écart constant (~381 031 GNF) qui n'est PAS une fuite vivante.
-- On enregistre cet écart comme POINT ZÉRO ; le gardien ne signale plus que les divergences
-- NOUVELLES (au-delà de la baseline).
--
-- ⚠️ Appliquer APRÈS le backfill PART A (COMMIT) pour que le point zéro intègre les crédits
-- historiques. L'écart est de toute façon invariant au backfill (crédit = +solde ET +ledger).
-- Migration livrée — NON exécutée.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.pdg_treasury_baseline (
  id smallint PRIMARY KEY DEFAULT 1,
  ledger_offset numeric NOT NULL DEFAULT 0,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pdg_treasury_baseline_singleton CHECK (id = 1)
);

INSERT INTO public.pdg_treasury_baseline (id, ledger_offset, note)
SELECT 1,
  COALESCE((SELECT COALESCE(balance,0) FROM public.wallets w
            JOIN public.pdg_management p ON p.user_id = w.user_id AND p.is_active = true
            WHERE w.currency = 'GNF' LIMIT 1), 0)
  - (
    COALESCE((SELECT sum(net_amount) FROM public.wallet_transactions wt
      JOIN public.wallets w ON w.id = wt.receiver_wallet_id
      JOIN public.pdg_management p ON p.user_id = w.user_id AND p.is_active = true
      WHERE w.currency = 'GNF' AND wt.status = 'completed'), 0)
    - COALESCE((SELECT sum(net_amount) FROM public.wallet_transactions wt
      JOIN public.wallets w ON w.id = wt.sender_wallet_id
      JOIN public.pdg_management p ON p.user_id = w.user_id AND p.is_active = true
      WHERE w.currency = 'GNF' AND wt.status = 'completed'), 0)
    - COALESCE((SELECT sum(abs(amount)) FROM public.platform_revenue
      WHERE revenue_type = 'agent_commission_payout' AND amount < 0), 0)
  ),
  'Baseline pré-coffre (héritage) — écart neutralisé au ' || now()::date
ON CONFLICT (id) DO UPDATE SET ledger_offset = EXCLUDED.ledger_offset, created_at = now();

-- Le gardien soustrait la baseline dans treasury_balance_vs_ledger (contrôle #2).
CREATE OR REPLACE FUNCTION public.pdg_treasury_monitor_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pdg_user_id uuid; v_wallet_id bigint; v_balance numeric := 0;
  v_credits numeric := 0; v_debits numeric := 0; v_agent_payouts numeric := 0;
  v_expected numeric := 0; v_baseline numeric := 0;
  v_low_threshold numeric := public.pdg_setting_numeric('pdg_wallet_low_threshold', 100000);
  v_not_credited int := 0; v_ledger_gap int := 0; v_ledger_amount numeric := 0;
  v_payout_no_debit int := 0; v_commission_no_debit int := 0;
  v_percent_overflow int := 0; v_low_balance int := 0; v_sub_missing int := 0;
BEGIN
  SELECT user_id INTO v_pdg_user_id FROM public.pdg_management WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1;
  SELECT id, COALESCE(balance,0) INTO v_wallet_id, v_balance FROM public.wallets WHERE user_id = v_pdg_user_id AND currency = 'GNF';
  SELECT COALESCE(ledger_offset,0) INTO v_baseline FROM public.pdg_treasury_baseline WHERE id = 1;

  SELECT count(*) INTO v_not_credited FROM public.revenus_pdg WHERE credited_to_wallet = false AND created_at < now() - interval '5 minutes';

  IF v_wallet_id IS NOT NULL THEN
    SELECT COALESCE(sum(net_amount),0) INTO v_credits FROM public.wallet_transactions WHERE receiver_wallet_id = v_wallet_id AND status = 'completed';
    SELECT COALESCE(sum(net_amount),0) INTO v_debits FROM public.wallet_transactions WHERE sender_wallet_id = v_wallet_id AND status = 'completed';
    SELECT COALESCE(sum(abs(amount)),0) INTO v_agent_payouts FROM public.platform_revenue WHERE revenue_type = 'agent_commission_payout' AND amount < 0;
    v_expected := v_credits - v_debits - v_agent_payouts;
    v_ledger_amount := round(v_balance - v_expected - v_baseline, 2);
    IF abs(v_ledger_amount) > 1 THEN v_ledger_gap := 1; END IF;
  END IF;

  SELECT count(*) INTO v_payout_no_debit FROM public.shareholder_payments sp
  WHERE sp.status = 'sent_to_wallet'
    AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions wt WHERE wt.transaction_id = 'shareholder_payout:' || sp.id::text);

  SELECT count(DISTINCT acl.transaction_id) INTO v_commission_no_debit FROM public.agent_commissions_log acl
  WHERE acl.status = 'validated' AND acl.transaction_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.platform_revenue pr WHERE pr.revenue_type = 'agent_commission_payout' AND pr.source_transaction_id = acl.transaction_id);

  SELECT count(*) INTO v_percent_overflow FROM (
    SELECT 1 FROM public.shareholder_assignments WHERE status = 'active'
    GROUP BY category, action_scope, country HAVING sum(COALESCE(percentage,0)) > 100) d;

  IF v_wallet_id IS NOT NULL AND v_balance < v_low_threshold THEN v_low_balance := 1; END IF;

  SELECT
    (SELECT count(*) FROM public.subscriptions s WHERE s.status = 'active' AND s.created_at < now() - interval '10 minutes' AND COALESCE(s.price_paid_gnf,0) > 0
      AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r WHERE r.source_type = 'abonnement_vendeur' AND r.transaction_id = s.id))
  + (SELECT count(*) FROM public.service_subscriptions ss WHERE ss.status = 'active' AND ss.created_at < now() - interval '10 minutes' AND COALESCE(ss.price_paid_gnf,0) > 0
      AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r WHERE r.source_type = 'abonnement_service' AND r.transaction_id = ss.id))
  INTO v_sub_missing;

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','revenue_not_credited','label','Revenus journalisés non crédités au coffre (> 5 min)','severity','high','count',v_not_credited,'observed',v_not_credited),
    jsonb_build_object('key','treasury_balance_vs_ledger','label','Invariant du coffre rompu (solde ≠ crédits − débits) — mouvement hors circuit','severity','critical','count',v_ledger_gap,'observed',v_ledger_amount),
    jsonb_build_object('key','payout_without_treasury_debit','label','Versement actionnaire SANS débit du coffre (mint ex nihilo)','severity','critical','count',v_payout_no_debit,'observed',v_payout_no_debit),
    jsonb_build_object('key','commission_without_treasury_debit','label','Commission agent SANS trace de débit coffre (mint pré-ledger)','severity','high','count',v_commission_no_debit,'observed',v_commission_no_debit),
    jsonb_build_object('key','shareholder_percent_overflow','label','Somme des parts actionnaires > 100 % (catégorie/portée/pays)','severity','high','count',v_percent_overflow,'observed',v_percent_overflow),
    jsonb_build_object('key','treasury_low_balance','label','Solde du coffre sous le seuil bas','severity','medium','count',v_low_balance,'observed',v_balance),
    jsonb_build_object('key','subscription_revenue_missing','label','Abonnements payés SANS revenu journalisé (flux oublié)','severity','high','count',v_sub_missing,'observed',v_sub_missing)
  ));
END; $$;

REVOKE ALL ON FUNCTION public.pdg_treasury_monitor_report() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pdg_treasury_monitor_report() TO service_role;

SELECT 'baseline=' || (SELECT ledger_offset FROM public.pdg_treasury_baseline WHERE id=1)::text
  || ' · nouvel écart=' || ((public.pdg_treasury_monitor_report()->'checks'->1->>'observed')) AS status;
