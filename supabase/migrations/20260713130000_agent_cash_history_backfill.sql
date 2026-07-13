-- ============================================================================
-- BACKFILL OPTIONNEL (one-shot) — historique deux-faces des opérations agent-cash PASSÉES.
-- ----------------------------------------------------------------------------
-- Le trigger 20260713120000 ne fire que sur les FUTURES opérations. Ce script
-- rejoue la MÊME assemblage pour les dépôts/retraits déjà complétés qui n'ont pas
-- encore de ligne wallet_transactions (détection via idempotency_key déterministe).
--
-- 100 % SÛR : lecture seule d'agent_cash_operations + agent_cash_ledger, écriture
-- UNIQUEMENT dans wallet_transactions (historique). Ne touche AUCUN solde ni RPC.
-- Idempotent : re-jouable sans risque (ON CONFLICT (idempotency_key) DO NOTHING +
-- filtre NOT EXISTS). Chaque ligne conserve la DATE d'ORIGINE de l'opération.
-- Toute erreur sur une opération est journalisée et n'interrompt pas le lot.
-- ============================================================================

DO $$
DECLARE
  r RECORD;
  v_op text; v_parent uuid; v_client uuid; v_agent_id uuid;
  v_agent_user uuid; v_agent_name text; v_client_name text;
  v_client_amt numeric; v_client_cur text; v_client_fee numeric;
  v_agent_amt numeric; v_agent_cur text; v_fx_rate numeric; v_fx_at timestamptz;
  v_comm_amt numeric; v_comm_cur text; v_comm_paid boolean;
  v_cli_type transaction_type; v_agt_type transaction_type; v_base_meta jsonb;
  v_done int := 0; v_skip int := 0;
BEGIN
  FOR r IN
    SELECT o.* FROM public.agent_cash_operations o
    WHERE o.operation IN ('deposit','withdrawal') AND o.result IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions wt
                      WHERE wt.idempotency_key = 'acash_agt_' || o.parent_tx_id::text)
    ORDER BY o.created_at
  LOOP
    v_op := r.operation; v_parent := r.parent_tx_id; v_client := r.client_user_id; v_agent_id := r.agent_id;
    v_client_fee := 0; v_comm_amt := NULL; v_comm_cur := NULL; v_comm_paid := false;
    IF v_parent IS NULL OR v_client IS NULL OR v_agent_id IS NULL THEN v_skip := v_skip + 1; CONTINUE; END IF;

    BEGIN
      SELECT am.user_id, COALESCE(am.name,'Agent 224') INTO v_agent_user, v_agent_name
        FROM public.agents_management am WHERE am.id = v_agent_id;
      SELECT COALESCE(NULLIF(TRIM(p.full_name),''),
                      NULLIF(TRIM(COALESCE(p.first_name,'')||' '||COALESCE(p.last_name,'')),''),'Client')
        INTO v_client_name FROM public.profiles p WHERE p.id = v_client;

      IF v_op = 'withdrawal' THEN
        SELECT l.amount,l.currency,l.fx_rate,l.fx_rate_at INTO v_agent_amt,v_agent_cur,v_fx_rate,v_fx_at
          FROM public.agent_cash_ledger l WHERE l.parent_tx_id=v_parent AND l.leg='agent_wallet_credit' LIMIT 1;
        SELECT l.amount,l.currency INTO v_client_amt,v_client_cur
          FROM public.agent_cash_ledger l WHERE l.parent_tx_id=v_parent AND l.leg='client_debit' LIMIT 1;
        v_client_fee := GREATEST(COALESCE(v_client_amt,0)-COALESCE(r.amount,0),0);
        v_client_amt := COALESCE(r.amount,v_client_amt);
        v_cli_type := 'withdrawal'; v_agt_type := 'deposit';
      ELSE
        SELECT l.amount,l.currency,l.fx_rate,l.fx_rate_at INTO v_agent_amt,v_agent_cur,v_fx_rate,v_fx_at
          FROM public.agent_cash_ledger l WHERE l.parent_tx_id=v_parent AND l.leg='agent_wallet_debit' LIMIT 1;
        SELECT l.amount,l.currency INTO v_client_amt,v_client_cur
          FROM public.agent_cash_ledger l WHERE l.parent_tx_id=v_parent AND l.leg='client_credit' LIMIT 1;
        v_client_fee := 0; v_cli_type := 'deposit'; v_agt_type := 'withdrawal';
      END IF;

      IF v_client_amt IS NULL OR v_agent_amt IS NULL THEN v_skip := v_skip + 1; CONTINUE; END IF;

      SELECT EXISTS(SELECT 1 FROM public.agent_cash_ledger l
                    WHERE l.parent_tx_id=v_parent AND l.leg='pdg_commission_debit') INTO v_comm_paid;
      IF v_comm_paid THEN
        SELECT l.amount,l.currency INTO v_comm_amt,v_comm_cur
          FROM public.agent_cash_ledger l WHERE l.parent_tx_id=v_parent AND l.leg='agent_commission_credit' LIMIT 1;
      END IF;

      v_base_meta := jsonb_build_object('op_type','agent_cash_'||v_op,'parent_tx_id',v_parent,
        'amount_client',v_client_amt,'client_currency',v_client_cur,'amount_agent',v_agent_amt,'agent_currency',v_agent_cur,
        'fx_rate',v_fx_rate,'fx_rate_at',v_fx_at,'fees',v_client_fee,'fees_currency',v_client_cur,
        'commission_amount',v_comm_amt,'commission_currency',v_comm_cur,'commission_paid',COALESCE(v_comm_paid,false),
        'backfilled',true);

      -- LIGNE CLIENT (date d'origine préservée)
      INSERT INTO public.wallet_transactions (transaction_id,sender_user_id,receiver_user_id,amount,fee,net_amount,currency,transaction_type,status,description,reference_id,metadata,idempotency_key,created_at)
      VALUES ('acash_cli_'||v_parent::text,
        CASE WHEN v_op='withdrawal' THEN v_client ELSE v_agent_user END,
        CASE WHEN v_op='withdrawal' THEN v_agent_user ELSE v_client END,
        (v_client_amt+v_client_fee),v_client_fee,v_client_amt,v_client_cur,v_cli_type,'completed',
        CASE WHEN v_op='withdrawal' THEN 'Retrait cash chez '||v_agent_name ELSE 'Dépôt cash chez '||v_agent_name END,
        v_parent::text,
        v_base_meta||jsonb_build_object('side','client','counterparty_name',v_agent_name,
          'sender_name',CASE WHEN v_op='withdrawal' THEN 'Vous' ELSE v_agent_name END,
          'receiver_name',CASE WHEN v_op='withdrawal' THEN v_agent_name ELSE 'Vous' END),
        'acash_cli_'||v_parent::text, r.created_at)
      ON CONFLICT (idempotency_key) DO NOTHING;

      -- LIGNE AGENT
      INSERT INTO public.wallet_transactions (transaction_id,sender_user_id,receiver_user_id,amount,fee,net_amount,currency,transaction_type,status,description,reference_id,metadata,idempotency_key,created_at)
      VALUES ('acash_agt_'||v_parent::text,
        CASE WHEN v_op='withdrawal' THEN v_client ELSE v_agent_user END,
        CASE WHEN v_op='withdrawal' THEN v_agent_user ELSE v_client END,
        v_agent_amt,0,v_agent_amt,v_agent_cur,v_agt_type,'completed',
        CASE WHEN v_op='withdrawal' THEN 'Retrait client '||v_client_name ELSE 'Dépôt client '||v_client_name END,
        v_parent::text,
        v_base_meta||jsonb_build_object('side','agent','counterparty_name',v_client_name,
          'sender_name',CASE WHEN v_op='withdrawal' THEN v_client_name ELSE 'Vous' END,
          'receiver_name',CASE WHEN v_op='withdrawal' THEN 'Vous' ELSE v_client_name END),
        'acash_agt_'||v_parent::text, r.created_at)
      ON CONFLICT (idempotency_key) DO NOTHING;

      -- LIGNE COMMISSION (si réellement créditée)
      IF v_comm_paid AND COALESCE(v_comm_amt,0) > 0 THEN
        INSERT INTO public.wallet_transactions (transaction_id,sender_user_id,receiver_user_id,amount,fee,net_amount,currency,transaction_type,status,description,reference_id,metadata,idempotency_key,created_at)
        VALUES ('acash_com_'||v_parent::text, NULL, v_agent_user, v_comm_amt,0,v_comm_amt,v_comm_cur,'commission','completed',
          'Commission cash — '||CASE WHEN v_op='withdrawal' THEN 'retrait' ELSE 'dépôt' END,
          v_parent::text,
          v_base_meta||jsonb_build_object('side','agent','op_type','agent_cash_commission','counterparty_name',v_client_name),
          'acash_com_'||v_parent::text, r.created_at)
        ON CONFLICT (idempotency_key) DO NOTHING;
      END IF;

      v_done := v_done + 1;
    EXCEPTION WHEN OTHERS THEN
      v_skip := v_skip + 1;
      BEGIN
        PERFORM public.agent_audit_log_safe('warning','agent_cash_history_backfill_failed',
          jsonb_build_object('parent_tx_id',v_parent,'op',v_op,'err',SQLERRM));
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END;
  END LOOP;

  RAISE NOTICE 'Backfill agent-cash historique : % opérations backfillées, % ignorées/erreurs.', v_done, v_skip;
END $$;
