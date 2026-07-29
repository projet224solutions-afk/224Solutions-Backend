-- ============================================================================
-- INVARIANT DE CONSERVATION Σ (chantier D) — dépôts/règlements = crédités + frais + quarantaine
-- ----------------------------------------------------------------------------
-- Pour chaque règlement prestataire (payment_transactions completed, providers momo/carte réglés
-- via settle_qr_payment), le MONTANT (converti si FX) == crédit vendeur + quarantaine vendeur +
-- frais PDG, joints par (source_type 'qr_<provider>' / '_fee', provider_ref). PROUVÉ exact sur un
-- règlement réel (10 M → 0 crédité + 10 M quarantaine + 0 frais == 10 M). Discipline « au centime » :
-- modèle COMPLET (couvre le cas FX via amount_converted), pas d'assouplissement.
-- Borné aux données POST-DURCISSEMENT (>= 29/07) — les données legacy (avant les ledgers actuels)
-- sont sorties en contrôle « information » NON bloquant (elles ne suivent pas ce modèle par construction).
-- ============================================================================

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
  SELECT count(*) INTO v_n FROM public.wallet_quarantined_funds qf
   WHERE qf.created_at >= DATE '2026-07-29' AND qf.source_transaction_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.wallet_credit_idempotency wci WHERE wci.source_txn_id=qf.source_transaction_id AND wci.source_type=qf.source_type)
     AND NOT EXISTS (SELECT 1 FROM public.enhanced_transactions et WHERE et.id::text=qf.source_transaction_id);
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details) VALUES ('quarantine_traces_to_credit',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run)); v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  -- 13) CONSERVATION Σ : par règlement (payment_transactions completed post-durcissement, providers
  --     réglés via settle_qr_payment), montant (converti si FX) == crédit + quarantaine + frais.
  SELECT count(*) INTO v_n FROM (
    SELECT COALESCE((pt.metadata->'fx'->>'amount_converted')::numeric, pt.amount) AS gross,
      (SELECT COALESCE(sum(credited),0) FROM public.wallet_credit_idempotency WHERE source_type='qr_'||pt.provider AND source_txn_id=pt.provider_ref) AS v_cred,
      (SELECT COALESCE(sum(amount),0)   FROM public.wallet_quarantined_funds  WHERE source_type='qr_'||pt.provider AND source_transaction_id=pt.provider_ref) AS v_quar,
      (SELECT COALESCE(sum(credited),0) FROM public.wallet_credit_idempotency WHERE source_type='qr_'||pt.provider||'_fee' AND source_txn_id=pt.provider_ref) AS v_fee
    FROM public.payment_transactions pt
    WHERE pt.status='completed' AND pt.created_at >= DATE '2026-07-29' AND pt.provider IN ('djomy','cinetpay')
  ) c WHERE abs(c.gross - (c.v_cred + c.v_quar + c.v_fee)) > 0.01;
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('settlement_conservation',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run,'model','montant==credite+quarantaine+frais (FX via amount_converted)','scope','>=2026-07-29, providers djomy|cinetpay'));
  v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  -- INFO (non bloquant) : règlements prestataire legacy (avant durcissement) — ne suivent pas le
  -- modèle par construction ; on les COMPTE pour visibilité, sans jamais alerter (ok toujours true).
  SELECT count(*) INTO v_n FROM public.payment_transactions
   WHERE status='completed' AND created_at < DATE '2026-07-29' AND provider IN ('djomy','cinetpay','stripe');
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('settlement_legacy_info', v_n, v_n, 0, true, jsonb_build_object('run',v_run,'note','information seulement (legacy pre-durcissement, non bloquant)'));
  -- (non compté dans v_total/v_bad : purement informatif)

  IF v_bad > 0 THEN
    INSERT INTO public.system_alerts(severity,module,title,message,metadata)
    VALUES ('critical','ledger_integrity','DÉRIVE COMPTABLE détectée ('||v_bad||'/'||v_total||' invariants rouges)',
      'Au moins un invariant comptable a un écart. Voir ledger_integrity_checks (run '||v_run||').',
      jsonb_build_object('run',v_run,'bad',v_bad,'total',v_total));
  END IF;
  RETURN jsonb_build_object('run',v_run,'checked_at',now(),'total',v_total,'bad',v_bad,'all_ok',v_bad=0);
END $function$;
