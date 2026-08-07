-- ═══════════════════════════════════════════════════════════════════════════
-- GARDIENS EXPLOITABLES — baseline de l'historique + détail actionnable.
--
-- CONSTAT (diagnostic du 07/08/2026, données réelles) : 4 alertes critiques criaient sur des
-- faits ANTÉRIEURS à la mise en service des mécanismes qu'elles surveillent :
--   • coffre : wallet PDG créé le 10/01/2026, 1re ligne de ledger le 16/06/2026 → 5 mois de
--     mouvements pré-ledger comptés comme un « trou » de ~2,3 M GNF ;
--   • versement actionnaire « ex nihilo » : 1 cas du 24/05/2026 (avant le débit de coffre) ;
--   • commission agent sans débit : 1 cas du 29/06/2026 (mint pré-ledger) ;
--   • abonnements sans revenu : 2 cas de janvier et juin 2026 (avant la journalisation V3).
-- Une alerte critique perpétuelle sur un fait figé n'est pas une surveillance : c'est du bruit
-- qui APPREND AU PDG À IGNORER LES SMS. On BASELINE donc l'historique (borne datée en config,
-- traçable et modifiable) et les gardiens ne jugent plus que le GOING-FORWARD.
--
-- ⚠️ RIEN N'EST EFFACÉ : les faits historiques restent lisibles via pdg_treasury_legacy_report()
-- (nouvelle RPC PDG) — ils sortent des ALERTES, pas des LIVRES.
--
-- + Le capteur AML « hausse sans transaction » devient ACTIONNABLE : il expose le DÉTAIL
--   (wallet, montant, date, rôle) au lieu d'un compteur nu, et accepte les traces ALTERNATIVES
--   légitimes (revenus_pdg, platform_revenue, agent_commissions_log) — une hausse tracée
--   ailleurs que dans wallet_transactions n'est pas de l'argent hors circuit.
-- Migration NOUVELLE. Aucune écriture sur un flux d'argent.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1) La borne de baseline (config PDG, modifiable, tracée) ────────────────
INSERT INTO public.pdg_settings (setting_key, setting_value, description)
VALUES ('guardian_baseline_at', jsonb_build_object('value', '2026-07-01T00:00:00Z'),
  'Borne des gardiens : les faits ANTÉRIEURS sont de l''historique pré-ledger (visibles via pdg_treasury_legacy_report), pas des alertes. Posée le 07/08/2026 après diagnostic.')
ON CONFLICT (setting_key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.guardian_baseline_at()
RETURNS timestamptz LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT (setting_value->>'value')::timestamptz FROM public.pdg_settings
     WHERE setting_key = 'guardian_baseline_at'),
    '2026-07-01T00:00:00Z'::timestamptz);
$$;
GRANT EXECUTE ON FUNCTION public.guardian_baseline_at() TO authenticated, service_role;

-- ── 2) GARDIEN DU COFFRE : invariant mesuré DEPUIS la baseline ──────────────
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
BEGIN
  SELECT user_id INTO v_pdg_user_id FROM public.pdg_management
  WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1;
  SELECT id, COALESCE(balance,0) INTO v_wallet_id, v_balance FROM public.wallets
  WHERE user_id = v_pdg_user_id AND currency = 'GNF';

  SELECT count(*) INTO v_not_credited FROM public.revenus_pdg
  WHERE credited_to_wallet = false AND created_at < now() - interval '5 minutes';

  -- INVARIANT DU COFFRE, GOING-FORWARD : solde d'ouverture à la baseline + crédits − débits
  -- − payouts, tous postérieurs à la baseline. L'ère pré-ledger n'est plus comptée comme un trou.
  IF v_wallet_id IS NOT NULL THEN
    SELECT COALESCE(sum(net_amount),0) INTO v_credits FROM public.wallet_transactions
    WHERE receiver_wallet_id = v_wallet_id AND status = 'completed' AND created_at >= v_since;
    SELECT COALESCE(sum(net_amount),0) INTO v_debits FROM public.wallet_transactions
    WHERE sender_wallet_id = v_wallet_id AND status = 'completed' AND created_at >= v_since;
    SELECT COALESCE(sum(abs(amount)),0) INTO v_agent_payouts FROM public.platform_revenue
    WHERE revenue_type = 'agent_commission_payout' AND amount < 0 AND created_at >= v_since;
    -- Solde d'ouverture = dernier solde connu AVANT la baseline (audit de solde), sinon 0.
    SELECT COALESCE((SELECT new_balance FROM public.wallet_balance_audit
                     WHERE wallet_id = v_wallet_id AND changed_at < v_since
                     ORDER BY changed_at DESC LIMIT 1), 0) INTO v_opening;
    v_expected := v_opening + v_credits - v_debits - v_agent_payouts;
    v_ledger_amount := round(v_balance - v_expected, 2);
    IF abs(v_ledger_amount) > 1 THEN v_ledger_gap := 1; END IF;
  END IF;

  -- Versements actionnaires SANS débit coffre — going-forward.
  SELECT count(*) INTO v_payout_no_debit FROM public.shareholder_payments sp
  WHERE sp.status = 'sent_to_wallet' AND sp.created_at >= v_since
    AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions wt
                    WHERE wt.transaction_id = 'shareholder_payout:' || sp.id::text);

  -- Commissions agents SANS débit coffre — going-forward.
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

  -- Abonnements payés SANS revenu journalisé — going-forward.
  SELECT
    (SELECT count(*) FROM public.subscriptions s
      WHERE s.status = 'active' AND s.created_at < now() - interval '10 minutes'
        AND s.created_at >= v_since AND COALESCE(s.price_paid_gnf,0) > 0
        AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r WHERE r.source_type = 'abonnement_vendeur'
                        AND r.transaction_id = s.id))
  + (SELECT count(*) FROM public.service_subscriptions ss
      WHERE ss.status = 'active' AND ss.created_at < now() - interval '10 minutes'
        AND ss.created_at >= v_since AND COALESCE(ss.price_paid_gnf,0) > 0
        AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r WHERE r.source_type = 'abonnement_service'
                        AND r.transaction_id = ss.id))
  INTO v_sub_missing;

  RETURN jsonb_build_object('generated_at', now(), 'baseline_at', v_since, 'checks', jsonb_build_array(
    jsonb_build_object('key','revenue_not_credited','label','Revenus journalisés non crédités au coffre (> 5 min)','severity','high','count',v_not_credited,'observed',v_not_credited),
    jsonb_build_object('key','treasury_balance_vs_ledger','label','Invariant du coffre rompu (solde ≠ ouverture + crédits − débits) — mouvement hors circuit','severity','critical','count',v_ledger_gap,'observed',v_ledger_amount),
    jsonb_build_object('key','payout_without_treasury_debit','label','Versement actionnaire SANS débit du coffre (mint ex nihilo)','severity','critical','count',v_payout_no_debit,'observed',v_payout_no_debit),
    jsonb_build_object('key','commission_without_treasury_debit','label','Commission agent SANS trace de débit coffre (mint pré-ledger)','severity','high','count',v_commission_no_debit,'observed',v_commission_no_debit),
    jsonb_build_object('key','shareholder_percent_overflow','label','Somme des parts actionnaires > 100 % (catégorie/portée/pays)','severity','high','count',v_percent_overflow,'observed',v_percent_overflow),
    jsonb_build_object('key','treasury_low_balance','label','Solde du coffre sous le seuil bas','severity','medium','count',v_low_balance,'observed',v_balance),
    jsonb_build_object('key','subscription_revenue_missing','label','Abonnements payés SANS revenu journalisé (flux oublié)','severity','high','count',v_sub_missing,'observed',v_sub_missing)
  ));
END; $$;
REVOKE ALL ON FUNCTION public.pdg_treasury_monitor_report() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pdg_treasury_monitor_report() TO service_role;

-- ── 3) L'HISTORIQUE RESTE LISIBLE (il sort des alertes, pas des livres) ─────
CREATE OR REPLACE FUNCTION public.pdg_treasury_legacy_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_since timestamptz := public.guardian_baseline_at();
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN jsonb_build_object(
    'baseline_at', v_since,
    'payouts_sans_debit', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id', sp.id, 'montant', sp.amount, 'le', sp.created_at, 'actionnaire', sp.shareholder_id))
      FROM public.shareholder_payments sp
      WHERE sp.status='sent_to_wallet' AND sp.created_at < v_since
        AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions wt
                        WHERE wt.transaction_id = 'shareholder_payout:' || sp.id::text)), '[]'::jsonb),
    'commissions_sans_debit', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'tx', acl.transaction_id, 'montant', acl.amount, 'le', acl.created_at))
      FROM public.agent_commissions_log acl
      WHERE acl.status='validated' AND acl.transaction_id IS NOT NULL AND acl.created_at < v_since
        AND NOT EXISTS (SELECT 1 FROM public.platform_revenue pr
                        WHERE pr.revenue_type='agent_commission_payout'
                          AND pr.source_transaction_id = acl.transaction_id)), '[]'::jsonb),
    'abonnements_sans_revenu', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id', s.id, 'prix', s.price_paid_gnf, 'le', s.created_at))
      FROM public.subscriptions s
      WHERE s.status='active' AND s.created_at < v_since AND COALESCE(s.price_paid_gnf,0) > 0
        AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r
                        WHERE r.source_type='abonnement_vendeur' AND r.transaction_id = s.id)), '[]'::jsonb));
END; $$;
REVOKE ALL ON FUNCTION public.pdg_treasury_legacy_report() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pdg_treasury_legacy_report() TO authenticated, service_role;

-- ── 4) CAPTEUR AML « hausse sans transaction » : traces alternatives + détail ──
-- Une hausse de solde tracée dans revenus_pdg / platform_revenue / agent_commissions_log
-- n'est PAS de l'argent hors circuit : c'est une trace dans un autre livre. On ne signale
-- QUE ce qui n'a AUCUNE trace, going-forward, et on donne au PDG de quoi agir.
CREATE OR REPLACE FUNCTION public.aml_untraced_increases(p_limit int DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_since timestamptz := public.guardian_baseline_at();
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.quand DESC) FROM (
    SELECT wba.changed_at AS quand, wba.wallet_id, wba.user_id,
           (wba.new_balance - wba.old_balance) AS hausse, wba.currency,
           (SELECT role::text FROM public.profiles WHERE id = wba.user_id) AS role
    FROM public.wallet_balance_audit wba
    WHERE wba.new_balance > wba.old_balance AND wba.changed_at >= v_since
      AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions wt
                      WHERE (wt.receiver_wallet_id = wba.wallet_id OR wt.sender_wallet_id = wba.wallet_id)
                        AND wt.created_at BETWEEN wba.changed_at - interval '10 minutes' AND wba.changed_at + interval '10 minutes')
      AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r
                      WHERE r.user_id = wba.user_id
                        AND r.created_at BETWEEN wba.changed_at - interval '10 minutes' AND wba.changed_at + interval '10 minutes')
      AND NOT EXISTS (SELECT 1 FROM public.platform_revenue pr
                      WHERE pr.created_at BETWEEN wba.changed_at - interval '10 minutes' AND wba.changed_at + interval '10 minutes')
      AND NOT EXISTS (SELECT 1 FROM public.agent_commissions_log acl
                      WHERE acl.created_at BETWEEN wba.changed_at - interval '10 minutes' AND wba.changed_at + interval '10 minutes')
    ORDER BY wba.changed_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit,50),1),200)) x), '[]'::jsonb);
END; $$;
REVOKE ALL ON FUNCTION public.aml_untraced_increases(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.aml_untraced_increases(int) TO authenticated, service_role;

COMMIT;
