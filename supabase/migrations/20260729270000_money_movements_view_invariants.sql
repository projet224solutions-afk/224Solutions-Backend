-- ============================================================================
-- VUE UNIFIÉE v_money_movements (surveillance C.1) + invariants exacts supplémentaires
-- ----------------------------------------------------------------------------
-- Un seul endroit requêtable pour TOUT mouvement d'argent : qui, quoi, combien, devise, taux FX
-- si conversion, référence externe, circuit d'origine, horodatage. Base = ledger canonique
-- wallet_transactions (deposit/withdrawal/transfer/commission/refund/escrow…), + les états
-- amont/aval (paiements prestataire, retraits, quarantaine). Lecture réservée service_role
-- (le dashboard PDG interroge via le backend).
-- ============================================================================

CREATE OR REPLACE VIEW public.v_money_movements AS
  SELECT 'wallet_ledger'::text          AS circuit,
         wt.id::text                    AS ref_id,
         wt.transaction_id              AS reference,
         wt.transaction_type::text      AS movement_type,
         wt.receiver_user_id            AS beneficiary_user_id,
         wt.sender_user_id              AS counterparty_user_id,
         wt.amount                      AS amount,
         wt.currency                    AS currency,
         wt.status::text                AS status,
         NULLIF(wt.metadata->>'rate','')::numeric AS fx_rate,
         wt.created_at                  AS occurred_at
    FROM public.wallet_transactions wt
  UNION ALL
  SELECT 'provider_payment', pt.id::text, pt.provider_ref, ('payin:'||pt.provider),
         pt.user_id, NULL::uuid, pt.amount, pt.currency, pt.status,
         NULLIF(pt.metadata->'fx'->>'rate','')::numeric, pt.created_at
    FROM public.payment_transactions pt
  UNION ALL
  SELECT 'withdrawal', w.id::text, w.payout_reference, ('withdraw:'||w.status),
         w.user_id, NULL::uuid, w.amount, w.currency, w.status,
         NULL::numeric, w.created_at
    FROM public.withdrawals w
  UNION ALL
  SELECT 'quarantine', q.id::text, NULL, ('quarantine:'||q.status),
         q.user_id, NULL::uuid, q.amount, q.currency, q.status,
         NULL::numeric, q.created_at
    FROM public.wallet_quarantined_funds q;

REVOKE ALL ON public.v_money_movements FROM PUBLIC, anon, authenticated;
GRANT  SELECT ON public.v_money_movements TO service_role;

-- Invariants exacts supplémentaires ajoutés au compteur de dérive (motif identique : rouge = écart).
CREATE OR REPLACE FUNCTION public.run_ledger_integrity_check()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_run uuid := gen_random_uuid(); v_bad int := 0; v_total int := 0; v_n numeric;
BEGIN
  SELECT count(*) INTO v_n FROM public.wallets WHERE COALESCE(balance,0) < 0;
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('no_negative_wallet',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run));
  v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  SELECT count(*) INTO v_n FROM public.agent_cash_deposit_lots WHERE amount_remaining < 0;
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('fifo_no_negative_remaining',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run));
  v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  SELECT count(*) INTO v_n FROM public.agent_cash_deposit_lots WHERE amount_remaining > amount_initial;
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('fifo_not_overconsumed',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run));
  v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  SELECT count(*) INTO v_n FROM public.wallet_quarantined_funds WHERE status NOT IN ('pending','released','rejected');
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('quarantine_status_valid',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run));
  v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  SELECT count(*) INTO v_n FROM public.withdrawals
   WHERE (status='paid' AND refunded_at IS NOT NULL) OR (status='refunded' AND paid_at IS NOT NULL)
      OR amount<0 OR status NOT IN ('pending','processing','paid','refunded','failed');
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('withdrawals_state_coherent',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run));
  v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  SELECT count(*) INTO v_n FROM public.payment_transactions WHERE status='completed' AND credited_at IS NULL;
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('payment_completed_has_credit',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run));
  v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  SELECT count(*) INTO v_n FROM (SELECT provider,provider_ref FROM public.payment_transactions
    WHERE credited_at IS NOT NULL GROUP BY provider,provider_ref HAVING count(*)>1) d;
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('payment_no_double_credit',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run));
  v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  -- 8) Aucune preuve de crédit consommée deux fois (source_type, source_txn_id) — anti double-crédit AML.
  SELECT count(*) INTO v_n FROM (SELECT source_type, source_txn_id FROM public.wallet_credit_idempotency
    WHERE source_txn_id IS NOT NULL GROUP BY source_type, source_txn_id HAVING count(*)>1) d;
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('credit_idempotency_no_dupe',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run));
  v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  -- 9) Tout retrait 'paid' a une référence de versement (traçabilité du payout).
  SELECT count(*) INTO v_n FROM public.withdrawals WHERE status='paid' AND (payout_reference IS NULL OR btrim(payout_reference)='');
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('withdrawal_paid_has_reference',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run));
  v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  -- 10) Toute quarantaine 'released'/'rejected' a un réviseur + date (pas de sortie orpheline).
  SELECT count(*) INTO v_n FROM public.wallet_quarantined_funds
   WHERE status IN ('released','rejected') AND (reviewed_by IS NULL OR reviewed_at IS NULL);
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('quarantine_reviewed_has_reviewer',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run));
  v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  -- 11) Aucun règlement bloqué en pending_fx depuis > 1 h (doit être relancé par la réconciliation).
  SELECT count(*) INTO v_n FROM public.payment_transactions
   WHERE status='pending_fx' AND updated_at < now() - interval '1 hour';
  INSERT INTO public.ledger_integrity_checks(check_name,expected,actual,drift,ok,details)
  VALUES ('no_stale_pending_fx',0,v_n,v_n,v_n=0,jsonb_build_object('run',v_run));
  v_total:=v_total+1; IF v_n<>0 THEN v_bad:=v_bad+1; END IF;

  IF v_bad > 0 THEN
    INSERT INTO public.system_alerts(severity,module,title,message,metadata)
    VALUES ('critical','ledger_integrity',
      'DÉRIVE COMPTABLE détectée ('||v_bad||'/'||v_total||' invariants rouges)',
      'Au moins un invariant comptable a un écart. Voir ledger_integrity_checks (run '||v_run||').',
      jsonb_build_object('run',v_run,'bad',v_bad,'total',v_total));
  END IF;
  RETURN jsonb_build_object('run',v_run,'checked_at',now(),'total',v_total,'bad',v_bad,'all_ok',v_bad=0);
END $function$;
