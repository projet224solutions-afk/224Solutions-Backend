-- ═══════════════════════════════════════════════════════════════════════════
-- COFFRE PDG — solde d'ouverture ACTÉ + le vrai défaut RENDU VISIBLE.
--
-- DIAGNOSTIC ÉTABLI (07/08/2026, données réelles) : l'écart du coffre n'est PAS une perte.
-- Depuis le 01/07, **2 515 387,08 GNF sont réellement ENTRÉS** dans le coffre SANS ligne
-- `wallet_transactions` : `credit_user_wallet_safe` crédite le solde mais n'écrit AUCUNE
-- ligne de grand livre — c'est l'APPELANT qui doit le faire. Les ~25 fonctions qui créditent
-- le PDG (release_escrow_to_seller, pay_quote_atomic, settle_qr_payment…) écrivent la ligne
-- du BÉNÉFICIAIRE mais pas celle du coffre. L'argent est encaissé ; c'est sa TRAÇABILITÉ
-- qui manque. Conséquences : gardien qui hurle sans fin, et compta PDG (qui lit
-- wallet_transactions) qui SOUS-COMPTE les revenus du coffre.
--
-- CE QUE FAIT CETTE MIGRATION (sans toucher à AUCUNE primitive d'argent — ce chantier-là
-- se fait à froid, pas en fin de session) :
--   1. ACTE le solde d'ouverture du coffre à la borne (constante en config, traçable) :
--      l'invariant repart d'une base juste et détectera toute dérive FUTURE ;
--   2. REMPLACE le bruit par une mesure : nouveau contrôle `treasury_untraced_credit`
--      (severity high, pas critical : ce n'est pas une perte) qui chiffre EN CONTINU les
--      crédits du coffre sans ligne de grand livre, avec le DÉTAIL consultable côté PDG.
-- Migration NOUVELLE. Lecture seule sur l'argent.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1) Solde d'ouverture ACTÉ à la borne (mesuré, pas deviné) ───────────────
-- opening = solde actuel − (crédits − débits − payouts) postérieurs à la borne.
DO $$
DECLARE
  v_pdg uuid; v_wallet bigint; v_bal numeric; v_since timestamptz := public.guardian_baseline_at();
  v_cred numeric; v_deb numeric; v_pay numeric; v_opening numeric;
BEGIN
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1;
  SELECT id, COALESCE(balance,0) INTO v_wallet, v_bal FROM public.wallets WHERE user_id = v_pdg AND currency = 'GNF';
  IF v_wallet IS NULL THEN RETURN; END IF;
  SELECT COALESCE(sum(net_amount),0) INTO v_cred FROM public.wallet_transactions
    WHERE receiver_wallet_id = v_wallet AND status='completed' AND created_at >= v_since;
  SELECT COALESCE(sum(net_amount),0) INTO v_deb FROM public.wallet_transactions
    WHERE sender_wallet_id = v_wallet AND status='completed' AND created_at >= v_since;
  SELECT COALESCE(sum(abs(amount)),0) INTO v_pay FROM public.platform_revenue
    WHERE revenue_type='agent_commission_payout' AND amount < 0 AND created_at >= v_since;
  v_opening := round(v_bal - (v_cred - v_deb - v_pay), 2);

  INSERT INTO public.pdg_settings (setting_key, setting_value, description)
  VALUES ('treasury_opening_balance',
    jsonb_build_object('value', v_opening, 'measured_at', now(), 'baseline_at', v_since,
      'note', 'Solde d''ouverture ACTÉ du coffre GNF à la borne des gardiens. Inclut les crédits réels non journalisés au grand livre (défaut de traçabilité connu, cf. check treasury_untraced_credit). Ne PAS modifier sans re-mesure.'),
    'Coffre PDG : solde d''ouverture acté à la borne (07/08/2026).')
  ON CONFLICT (setting_key) DO NOTHING;
END $$;

-- ── 2) Gardien : ouverture actée + NOUVEAU contrôle des crédits non tracés ──
CREATE OR REPLACE FUNCTION public.pdg_treasury_monitor_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pdg_user_id uuid; v_wallet_id bigint; v_balance numeric := 0;
  v_credits numeric := 0; v_debits numeric := 0; v_agent_payouts numeric := 0;
  v_opening numeric := 0; v_expected numeric := 0;
  v_low_threshold numeric := public.pdg_setting_numeric('pdg_wallet_low_threshold', 100000);
  v_since timestamptz := public.guardian_baseline_at();
  v_not_credited int := 0; v_ledger_gap int := 0; v_ledger_amount numeric := 0;
  v_payout_no_debit int := 0; v_commission_no_debit int := 0;
  v_percent_overflow int := 0; v_low_balance int := 0; v_sub_missing int := 0;
  v_untraced_n int := 0; v_untraced_amt numeric := 0;
BEGIN
  SELECT user_id INTO v_pdg_user_id FROM public.pdg_management
  WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1;
  SELECT id, COALESCE(balance,0) INTO v_wallet_id, v_balance FROM public.wallets
  WHERE user_id = v_pdg_user_id AND currency = 'GNF';

  SELECT count(*) INTO v_not_credited FROM public.revenus_pdg
  WHERE credited_to_wallet = false AND created_at < now() - interval '5 minutes';

  IF v_wallet_id IS NOT NULL THEN
    SELECT COALESCE(sum(net_amount),0) INTO v_credits FROM public.wallet_transactions
    WHERE receiver_wallet_id = v_wallet_id AND status = 'completed' AND created_at >= v_since;
    SELECT COALESCE(sum(net_amount),0) INTO v_debits FROM public.wallet_transactions
    WHERE sender_wallet_id = v_wallet_id AND status = 'completed' AND created_at >= v_since;
    SELECT COALESCE(sum(abs(amount)),0) INTO v_agent_payouts FROM public.platform_revenue
    WHERE revenue_type = 'agent_commission_payout' AND amount < 0 AND created_at >= v_since;

    -- Ouverture ACTÉE (config) ; repli sur l'audit de solde si la constante manque.
    SELECT COALESCE(
      (SELECT (setting_value->>'value')::numeric FROM public.pdg_settings WHERE setting_key='treasury_opening_balance'),
      (SELECT new_balance FROM public.wallet_balance_audit
        WHERE wallet_id = v_wallet_id AND changed_at < v_since ORDER BY changed_at DESC LIMIT 1),
      0) INTO v_opening;

    v_expected := v_opening + v_credits - v_debits - v_agent_payouts;
    v_ledger_amount := round(v_balance - v_expected, 2);
    IF abs(v_ledger_amount) > 1 THEN v_ledger_gap := 1; END IF;

    -- 🆕 LE VRAI DÉFAUT, MESURÉ : crédits du coffre SANS ligne de grand livre, depuis la borne.
    -- Ce n'est pas une perte (l'argent est bien là) : c'est de la traçabilité manquante.
    SELECT count(*), COALESCE(sum(wba.new_balance - wba.old_balance), 0)
      INTO v_untraced_n, v_untraced_amt
    FROM public.wallet_balance_audit wba
    WHERE wba.wallet_id = v_wallet_id AND wba.changed_at >= v_since
      AND wba.new_balance > wba.old_balance
      AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions wt
                      WHERE wt.receiver_wallet_id = v_wallet_id
                        AND wt.created_at BETWEEN wba.changed_at - interval '10 minutes'
                                              AND wba.changed_at + interval '10 minutes');
  END IF;

  SELECT count(*) INTO v_payout_no_debit FROM public.shareholder_payments sp
  WHERE sp.status = 'sent_to_wallet' AND sp.created_at >= v_since
    AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions wt
                    WHERE wt.transaction_id = 'shareholder_payout:' || sp.id::text);

  SELECT count(DISTINCT acl.transaction_id) INTO v_commission_no_debit
  FROM public.agent_commissions_log acl
  WHERE acl.status = 'validated' AND acl.transaction_id IS NOT NULL AND acl.created_at >= v_since
    AND NOT EXISTS (SELECT 1 FROM public.platform_revenue pr
                    WHERE pr.revenue_type = 'agent_commission_payout'
                      AND pr.source_transaction_id = acl.transaction_id);

  SELECT count(*) INTO v_percent_overflow FROM (
    SELECT 1 FROM public.shareholder_assignments WHERE status = 'active'
    GROUP BY category, action_scope, country HAVING sum(COALESCE(percentage,0)) > 100) d;

  IF v_wallet_id IS NOT NULL AND v_balance < v_low_threshold THEN v_low_balance := 1; END IF;

  SELECT
    (SELECT count(*) FROM public.subscriptions s
      WHERE s.status='active' AND s.created_at < now() - interval '10 minutes'
        AND s.created_at >= v_since AND COALESCE(s.price_paid_gnf,0) > 0
        AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r WHERE r.source_type='abonnement_vendeur' AND r.transaction_id = s.id))
  + (SELECT count(*) FROM public.service_subscriptions ss
      WHERE ss.status='active' AND ss.created_at < now() - interval '10 minutes'
        AND ss.created_at >= v_since AND COALESCE(ss.price_paid_gnf,0) > 0
        AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r WHERE r.source_type='abonnement_service' AND r.transaction_id = ss.id))
  INTO v_sub_missing;

  RETURN jsonb_build_object('generated_at', now(), 'baseline_at', v_since, 'opening_balance', v_opening,
    'checks', jsonb_build_array(
    jsonb_build_object('key','revenue_not_credited','label','Revenus journalisés non crédités au coffre (> 5 min)','severity','high','count',v_not_credited,'observed',v_not_credited),
    jsonb_build_object('key','treasury_balance_vs_ledger','label','Invariant du coffre rompu (solde ≠ ouverture + crédits − débits) — mouvement hors circuit','severity','critical','count',v_ledger_gap,'observed',v_ledger_amount),
    jsonb_build_object('key','treasury_untraced_credit','label','Crédits du coffre SANS ligne de grand livre (traçabilité manquante — argent encaissé mais non journalisé)','severity','high','count',v_untraced_n,'observed',v_untraced_amt),
    jsonb_build_object('key','payout_without_treasury_debit','label','Versement actionnaire SANS débit du coffre (mint ex nihilo)','severity','critical','count',v_payout_no_debit,'observed',v_payout_no_debit),
    jsonb_build_object('key','commission_without_treasury_debit','label','Commission agent SANS trace de débit coffre (mint pré-ledger)','severity','high','count',v_commission_no_debit,'observed',v_commission_no_debit),
    jsonb_build_object('key','shareholder_percent_overflow','label','Somme des parts actionnaires > 100 % (catégorie/portée/pays)','severity','high','count',v_percent_overflow,'observed',v_percent_overflow),
    jsonb_build_object('key','treasury_low_balance','label','Solde du coffre sous le seuil bas','severity','medium','count',v_low_balance,'observed',v_balance),
    jsonb_build_object('key','subscription_revenue_missing','label','Abonnements payés SANS revenu journalisé (flux oublié)','severity','high','count',v_sub_missing,'observed',v_sub_missing)
  ));
END; $$;
REVOKE ALL ON FUNCTION public.pdg_treasury_monitor_report() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pdg_treasury_monitor_report() TO service_role;

-- ── 3) Le DÉTAIL des crédits non tracés du coffre (PDG-only, actionnable) ───
CREATE OR REPLACE FUNCTION public.pdg_treasury_untraced_credits(p_limit int DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_pdg uuid; v_wallet bigint; v_since timestamptz := public.guardian_baseline_at();
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1;
  SELECT id INTO v_wallet FROM public.wallets WHERE user_id = v_pdg AND currency = 'GNF';
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.quand DESC) FROM (
    SELECT wba.changed_at AS quand, (wba.new_balance - wba.old_balance) AS credit,
           wba.old_balance, wba.new_balance
    FROM public.wallet_balance_audit wba
    WHERE wba.wallet_id = v_wallet AND wba.changed_at >= v_since AND wba.new_balance > wba.old_balance
      AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions wt
                      WHERE wt.receiver_wallet_id = v_wallet
                        AND wt.created_at BETWEEN wba.changed_at - interval '10 minutes'
                                              AND wba.changed_at + interval '10 minutes')
    ORDER BY wba.changed_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit,50),1),200)) x), '[]'::jsonb);
END; $$;
REVOKE ALL ON FUNCTION public.pdg_treasury_untraced_credits(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pdg_treasury_untraced_credits(int) TO authenticated, service_role;

COMMIT;
