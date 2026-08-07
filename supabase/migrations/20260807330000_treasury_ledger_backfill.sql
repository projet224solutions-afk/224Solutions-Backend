-- ═══════════════════════════════════════════════════════════════════════════
-- COFFRE PDG — LA TRAÇABILITÉ RÉPARÉE (chantier de fond du diagnostic 07/08).
--
-- PROBLÈME : `credit_user_wallet_safe` crédite le solde sans écrire au grand livre ; les ~25
-- fonctions qui créditent le PDG écrivent la ligne du bénéficiaire, pas celle du coffre.
-- → 2 515 387,08 GNF encaissés mais absents de `wallet_transactions` (et donc de la compta PDG).
--
-- POURQUOI PAS UN TRIGGER, POURQUOI PAS LE PRIMITIF :
--   • modifier `credit_user_wallet_safe` = toucher LA primitive de tous les crédits d'argent,
--     avec un risque de DOUBLE COMPTAGE quand l'appelant écrit déjà sa ligne → non ;
--   • un trigger sur l'audit de solde s'exécuterait AVANT l'INSERT de l'appelant (même
--     transaction) et ne le verrait pas → doublons → non.
-- SOLUTION : journalisation DIFFÉRÉE. Un balayage qui ne traite que les mouvements de plus de
-- 15 minutes : à cet instant, toutes les transactions concurrentes sont COMMITÉES, donc
-- « aucune ligne en face » est une VÉRITÉ, plus une course. Idempotent par ligne d'audit
-- (`transaction_id = 'treasury-audit:<id>'`, UNIQUE). Ne touche JAMAIS un solde : écrit
-- seulement le journal manquant, à la DATE RÉELLE du mouvement (compta juste).
-- Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.treasury_ledger_backfill(p_limit int DEFAULT 200)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pdg uuid; v_wallet bigint; v_since timestamptz := public.guardian_baseline_at();
  v_row record; v_n int := 0; v_amt numeric := 0; v_txid text;
BEGIN
  SELECT user_id INTO v_pdg FROM public.pdg_management
  WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1;
  IF v_pdg IS NULL THEN RETURN jsonb_build_object('error', 'NO_ACTIVE_PDG'); END IF;
  SELECT id INTO v_wallet FROM public.wallets WHERE user_id = v_pdg AND currency = 'GNF';
  IF v_wallet IS NULL THEN RETURN jsonb_build_object('error', 'NO_PDG_WALLET'); END IF;

  FOR v_row IN
    SELECT wba.id, wba.changed_at, (wba.new_balance - wba.old_balance) AS credit, wba.currency
    FROM public.wallet_balance_audit wba
    WHERE wba.wallet_id = v_wallet
      AND wba.changed_at >= v_since
      AND wba.changed_at < now() - interval '15 minutes'   -- ⏳ tout est committé : plus de course
      AND wba.new_balance > wba.old_balance
      AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions wt
                      WHERE wt.receiver_wallet_id = v_wallet
                        AND wt.created_at BETWEEN wba.changed_at - interval '10 minutes'
                                              AND wba.changed_at + interval '10 minutes')
    ORDER BY wba.changed_at
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 1000)
  LOOP
    v_txid := 'treasury-audit:' || v_row.id::text;
    BEGIN
      INSERT INTO public.wallet_transactions (
        transaction_id, receiver_wallet_id, receiver_user_id, amount, net_amount, currency,
        transaction_type, status, description, metadata, created_at)
      VALUES (
        v_txid, v_wallet, v_pdg, v_row.credit, v_row.credit, COALESCE(v_row.currency, 'GNF'),
        'deposit', 'completed',
        'Crédit du coffre journalisé a posteriori (rattrapage de traçabilité)',
        jsonb_build_object('source', 'treasury_ledger_backfill', 'audit_id', v_row.id,
          'moved_at', v_row.changed_at, 'note',
          'Ligne de journal ajoutée par le rattrapage : le solde n''est PAS modifié.'),
        v_row.changed_at)   -- 📅 date RÉELLE du mouvement → la compta tombe dans le bon mois
      ON CONFLICT (transaction_id) DO NOTHING;
      IF FOUND THEN v_n := v_n + 1; v_amt := v_amt + v_row.credit; END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[treasury backfill] audit % : %', v_row.id, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object('journalised', v_n, 'amount', v_amt, 'since', v_since);
END; $$;
REVOKE ALL ON FUNCTION public.treasury_ledger_backfill(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.treasury_ledger_backfill(int) TO service_role;

-- Re-mesure de l'ouverture APRÈS journalisation : les crédits rattrapés entrent désormais dans
-- `crédits`, donc l'ouverture actée doit baisser d'autant, sinon l'invariant casserait.
CREATE OR REPLACE FUNCTION public.treasury_reset_opening()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pdg uuid; v_wallet bigint; v_bal numeric; v_since timestamptz := public.guardian_baseline_at();
  v_cred numeric; v_deb numeric; v_pay numeric; v_opening numeric; v_old numeric;
BEGIN
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1;
  SELECT id, COALESCE(balance,0) INTO v_wallet, v_bal FROM public.wallets WHERE user_id = v_pdg AND currency='GNF';
  IF v_wallet IS NULL THEN RETURN jsonb_build_object('error','NO_PDG_WALLET'); END IF;
  SELECT COALESCE(sum(net_amount),0) INTO v_cred FROM public.wallet_transactions
    WHERE receiver_wallet_id = v_wallet AND status='completed' AND created_at >= v_since;
  SELECT COALESCE(sum(net_amount),0) INTO v_deb FROM public.wallet_transactions
    WHERE sender_wallet_id = v_wallet AND status='completed' AND created_at >= v_since;
  SELECT COALESCE(sum(abs(amount)),0) INTO v_pay FROM public.platform_revenue
    WHERE revenue_type='agent_commission_payout' AND amount < 0 AND created_at >= v_since;
  v_opening := round(v_bal - (v_cred - v_deb - v_pay), 2);
  SELECT (setting_value->>'value')::numeric INTO v_old FROM public.pdg_settings
    WHERE setting_key = 'treasury_opening_balance';

  UPDATE public.pdg_settings
  SET setting_value = jsonb_build_object('value', v_opening, 'measured_at', now(),
        'baseline_at', v_since, 'previous', v_old,
        'note', 'Ouverture re-mesurée après rattrapage de traçabilité (treasury_ledger_backfill).'),
      updated_at = now()
  WHERE setting_key = 'treasury_opening_balance';

  RETURN jsonb_build_object('opening_before', v_old, 'opening_after', v_opening);
END; $$;
REVOKE ALL ON FUNCTION public.treasury_reset_opening() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.treasury_reset_opening() TO service_role;

COMMIT;

-- ── Planification : rattrapage horaire (le journal ne peut plus prendre de retard) ─────
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('treasury-ledger-backfill')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'treasury-ledger-backfill');
    PERFORM cron.schedule('treasury-ledger-backfill', '25 * * * *',
      'SELECT public.treasury_ledger_backfill(200); SELECT public.treasury_reset_opening();');
  ELSE
    RAISE WARNING 'pg_cron absent : planifier treasury_ledger_backfill autrement.';
  END IF;
END $$;
