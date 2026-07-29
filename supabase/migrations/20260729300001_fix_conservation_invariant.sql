-- Corrige l'invariant #12 « aucune quarantaine fantôme » : il ne couvrait QUE le chemin
-- credit_user_wallet_safe (wallet_credit_idempotency). Or le chemin TRANSFERT
-- (execute_atomic_wallet_transfer → apply_wallet_cap_split) quarantaine avec source_transaction_id =
-- id d'une enhanced_transactions (pas d'entrée wallet_credit_idempotency). Modèle incomplet →
-- faux positif sur une quarantaine légitime (ex. les 3,79 M released de Thierno). Correction :
-- la quarantaine doit tracer à un VRAI événement de crédit sur L'UN des deux ledgers. EXACT désormais.
CREATE OR REPLACE FUNCTION public.run_ledger_integrity_check()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_run uuid := gen_random_uuid(); v_bad int := 0; v_total int := 0; v_n numeric;
BEGIN
  SELECT count(*) INTO v_n FROM public.wallets WHERE COALESCE(balance,0) < 0;
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details) VALUES ('no_negative_wallet',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run)); v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;
  SELECT count(*) INTO v_n FROM public.agent_cash_deposit_lots WHERE amount_remaining < 0;
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details) VALUES ('fifo_no_negative_remaining',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run)); v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;
  SELECT count(*) INTO v_n FROM public.agent_cash_deposit_lots WHERE amount_remaining > amount_initial;
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details) VALUES ('fifo_not_overconsumed',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run)); v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;
  SELECT count(*) INTO v_n FROM public.wallet_quarantined_funds WHERE status NOT IN ('pending','released','rejected');
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details) VALUES ('quarantine_status_valid',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run)); v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;
  SELECT count(*) INTO v_n FROM public.withdrawals WHERE (status='paid' AND refunded_at IS NOT NULL) OR (status='refunded' AND paid_at IS NOT NULL) OR amount<0 OR status NOT IN ('pending','processing','paid','refunded','failed');
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details) VALUES ('withdrawals_state_coherent',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run)); v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;
  SELECT count(*) INTO v_n FROM public.payment_transactions WHERE status='completed' AND credited_at IS NULL;
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details) VALUES ('payment_completed_has_credit',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run)); v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;
  SELECT count(*) INTO v_n FROM (SELECT provider,provider_ref FROM public.payment_transactions WHERE credited_at IS NOT NULL GROUP BY provider,provider_ref HAVING count(*)>1) d;
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details) VALUES ('payment_no_double_credit',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run)); v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;
  SELECT count(*) INTO v_n FROM (SELECT source_type,source_txn_id FROM public.wallet_credit_idempotency WHERE source_txn_id IS NOT NULL GROUP BY source_type,source_txn_id HAVING count(*)>1) d;
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details) VALUES ('credit_idempotency_no_dupe',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run)); v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;
  SELECT count(*) INTO v_n FROM public.withdrawals WHERE status='paid' AND (payout_reference IS NULL OR btrim(payout_reference)='');
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details) VALUES ('withdrawal_paid_has_reference',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run)); v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;
  SELECT count(*) INTO v_n FROM public.wallet_quarantined_funds WHERE status IN ('released','rejected') AND (reviewed_by IS NULL OR reviewed_at IS NULL);
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details) VALUES ('quarantine_reviewed_has_reviewer',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run)); v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;
  SELECT count(*) INTO v_n FROM public.payment_transactions WHERE status='pending_fx' AND updated_at < now() - interval '1 hour';
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details) VALUES ('no_stale_pending_fx',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run)); v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  -- 12) CONSERVATION exacte : quarantaine (post-durcissement) trace à un événement de crédit réel,
  --     sur L'UN des deux ledgers : wallet_credit_idempotency (dépôts/QR) OU enhanced_transactions
  --     (transferts). Aucune quarantaine « de nulle part ». Legacy < 29/07 grandfather.
  SELECT count(*) INTO v_n FROM public.wallet_quarantined_funds qf
   WHERE qf.created_at >= DATE '2026-07-29' AND qf.source_transaction_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.wallet_credit_idempotency wci
                      WHERE wci.source_txn_id = qf.source_transaction_id AND wci.source_type = qf.source_type)
     AND NOT EXISTS (SELECT 1 FROM public.enhanced_transactions et
                      WHERE et.id::text = qf.source_transaction_id);
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('quarantine_traces_to_credit',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run,'ledgers','credit_idempotency|enhanced_transactions','grandfather','< 2026-07-29'));
  v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  IF v_bad > 0 THEN
    INSERT INTO public.system_alerts(severity,module,title,message,metadata)
    VALUES ('critical','ledger_integrity','DÉRIVE COMPTABLE détectée ('||v_bad||'/'||v_total||' invariants rouges)',
      'Au moins un invariant comptable a un écart. Voir ledger_integrity_checks (run '||v_run||').',
      jsonb_build_object('run',v_run,'bad',v_bad,'total',v_total));
  END IF;
  RETURN jsonb_build_object('run',v_run,'checked_at',now(),'total',v_total,'bad',v_bad,'all_ok',v_bad=0);
END $function$;
