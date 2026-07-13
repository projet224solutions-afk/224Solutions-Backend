-- ============================================================================
-- HISTORIQUE CROSS-DEVISES agent-cash : chaque partie voit LES DEUX FACES.
-- ----------------------------------------------------------------------------
-- CONSTAT : les RPC v2 (agent_cash_deposit / agent_cash_withdrawal) bougent les
-- soldes via _acash_debit_wallet / _acash_credit_wallet (UPDATE wallets.balance)
-- et tracent tout dans agent_cash_ledger, mais N'ÉCRIVENT AUCUNE ligne
-- public.wallet_transactions — la table lue par UniversalWalletTransactions.
-- Résultat : les opérations cash sont invisibles dans l'historique wallet.
--
-- CHOIX D'INGÉNIERIE (sécurité du flux monétaire) : plutôt que réécrire à la
-- main deux RPC argent de ~110 lignes (risque de transcription sur un flux réel),
-- on émet les lignes d'historique via un TRIGGER `AFTER UPDATE OF result` sur
-- agent_cash_operations. Il se déclenche UNE fois, quand l'opération est complète
-- (result passe de NULL → non-NULL, donc TOUS les legs agent_cash_ledger existent),
-- DANS LA MÊME TRANSACTION que la RPC → atomique. Il LIT les legs (source de
-- vérité) et écrit les wallet_transactions. ZÉRO changement de montants/flux,
-- toutes les gardes des RPC (COMMISSION_MANQUANTE, plafonds, FX, atomicité) sont
-- intactes puisqu'on ne touche pas aux RPC.
--
-- Ce que voit CHAQUE partie (grâce au dédup existant du frontend) :
--   • CLIENT  — retrait : ligne 'withdrawal' (sender=client) → débité (principal+frais)
--               en SA devise + metadata pour la sous-ligne « espèces reçues en devise agent ».
--             — dépôt   : ligne 'deposit'  (receiver=client) → crédité en SA devise.
--   • AGENT   — retrait : ligne 'deposit'  (receiver=agent) → +équivalent en SA devise.
--             — dépôt   : ligne 'withdrawal'(sender=agent)  → −équivalent en SA devise.
--             — commission : ligne 'commission' (receiver=agent) LIÉE par parent_tx_id,
--               émise UNIQUEMENT si la commission a réellement été créditée (leg
--               'pdg_commission_debit' présent — pas si elle est partie en pending).
--
-- Le montant brut/net respecte le CHECK net_amount = amount - fee. Le rendu à deux
-- faces est piloté par metadata.op_type côté frontend (dégradation propre : les
-- anciennes lignes sans metadata gardent leur rendu actuel). Idempotent
-- (idempotency_key/transaction_id UNIQUE + ON CONFLICT DO NOTHING).
--
-- Pas de backfill (l'historique passé reste tel quel — le trigger ne fire que sur
-- les futures opérations). Backfill optionnel possible par relecture d'agent_cash_ledger
-- (script séparé, non inclus).
-- ============================================================================

CREATE OR REPLACE FUNCTION public._acash_emit_wallet_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_op          text := NEW.operation;
  v_parent      uuid := NEW.parent_tx_id;
  v_client      uuid := NEW.client_user_id;
  v_agent_id    uuid := NEW.agent_id;
  v_agent_user  uuid;
  v_agent_name  text;
  v_client_name text;

  v_client_amt  numeric;   -- montant côté client (SA devise) : principal
  v_client_cur  text;
  v_client_fee  numeric := 0;
  v_agent_amt   numeric;   -- montant côté agent (SA devise)
  v_agent_cur   text;
  v_fx_rate     numeric;
  v_fx_at       timestamptz;
  v_comm_amt    numeric;
  v_comm_cur    text;
  v_comm_paid   boolean;

  v_cli_type    transaction_type;
  v_agt_type    transaction_type;
  v_base_meta   jsonb;
BEGIN
  -- Seuls dépôt/retrait produisent l'historique cash à deux faces.
  IF v_op NOT IN ('deposit', 'withdrawal') THEN RETURN NEW; END IF;
  IF v_parent IS NULL OR v_client IS NULL OR v_agent_id IS NULL THEN RETURN NEW; END IF;

  -- Émission best-effort : une défaillance d'historique ne doit JAMAIS annuler
  -- l'opération d'argent (déjà appliquée dans CETTE transaction). Toute erreur est
  -- JOURNALISÉE (agent_audit_log_safe) — jamais masquée en silence, jamais un rollback.
  BEGIN
  -- Identités (lecture seule).
  SELECT am.user_id, COALESCE(am.name, 'Agent 224')
    INTO v_agent_user, v_agent_name
  FROM public.agents_management am WHERE am.id = v_agent_id;

  SELECT COALESCE(NULLIF(TRIM(p.full_name), ''),
                  NULLIF(TRIM(COALESCE(p.first_name,'') || ' ' || COALESCE(p.last_name,'')), ''),
                  'Client')
    INTO v_client_name
  FROM public.profiles p WHERE p.id = v_client;

  -- ── Legs : côté agent (équivalent + taux) ──
  IF v_op = 'withdrawal' THEN
    SELECT l.amount, l.currency, l.fx_rate, l.fx_rate_at
      INTO v_agent_amt, v_agent_cur, v_fx_rate, v_fx_at
    FROM public.agent_cash_ledger l
    WHERE l.parent_tx_id = v_parent AND l.leg = 'agent_wallet_credit' LIMIT 1;
    -- Côté client : le leg 'client_debit' porte (principal + frais). Principal = operations.amount.
    SELECT l.amount, l.currency INTO v_client_amt, v_client_cur
    FROM public.agent_cash_ledger l
    WHERE l.parent_tx_id = v_parent AND l.leg = 'client_debit' LIMIT 1;
    v_client_fee  := GREATEST(COALESCE(v_client_amt, 0) - COALESCE(NEW.amount, 0), 0);
    v_client_amt  := COALESCE(NEW.amount, v_client_amt);   -- principal (hors frais)
    v_cli_type := 'withdrawal';   -- sortant côté client
    v_agt_type := 'deposit';      -- entrant côté agent
  ELSE  -- deposit
    SELECT l.amount, l.currency, l.fx_rate, l.fx_rate_at
      INTO v_agent_amt, v_agent_cur, v_fx_rate, v_fx_at
    FROM public.agent_cash_ledger l
    WHERE l.parent_tx_id = v_parent AND l.leg = 'agent_wallet_debit' LIMIT 1;
    SELECT l.amount, l.currency INTO v_client_amt, v_client_cur
    FROM public.agent_cash_ledger l
    WHERE l.parent_tx_id = v_parent AND l.leg = 'client_credit' LIMIT 1;
    v_client_fee := 0;
    v_cli_type := 'deposit';       -- entrant côté client
    v_agt_type := 'withdrawal';    -- sortant côté agent
  END IF;

  IF v_client_amt IS NULL OR v_agent_amt IS NULL THEN RETURN NEW; END IF;  -- rien à écrire

  -- ── Commission agent : émise SEULEMENT si réellement créditée (leg pdg_commission_debit présent) ──
  SELECT EXISTS (SELECT 1 FROM public.agent_cash_ledger l
                 WHERE l.parent_tx_id = v_parent AND l.leg = 'pdg_commission_debit')
    INTO v_comm_paid;
  IF v_comm_paid THEN
    SELECT l.amount, l.currency INTO v_comm_amt, v_comm_cur
    FROM public.agent_cash_ledger l
    WHERE l.parent_tx_id = v_parent AND l.leg = 'agent_commission_credit' LIMIT 1;
  END IF;

  -- Métadonnées communes (les deux faces + taux + frais + commission liée).
  v_base_meta := jsonb_build_object(
    'op_type',           'agent_cash_' || v_op,
    'parent_tx_id',      v_parent,
    'amount_client',     v_client_amt,
    'client_currency',   v_client_cur,
    'amount_agent',      v_agent_amt,
    'agent_currency',    v_agent_cur,
    'fx_rate',           v_fx_rate,
    'fx_rate_at',        v_fx_at,
    'fees',              v_client_fee,
    'fees_currency',     v_client_cur,
    'commission_amount', v_comm_amt,
    'commission_currency', v_comm_cur,
    'commission_paid',   COALESCE(v_comm_paid, false)
  );

  -- ── LIGNE CLIENT ──
  INSERT INTO public.wallet_transactions
    (transaction_id, sender_user_id, receiver_user_id, amount, fee, net_amount, currency,
     transaction_type, status, description, reference_id, metadata, idempotency_key, created_at)
  VALUES (
    'acash_cli_' || v_parent::text,
    CASE WHEN v_op = 'withdrawal' THEN v_client ELSE v_agent_user END,   -- sender
    CASE WHEN v_op = 'withdrawal' THEN v_agent_user ELSE v_client END,   -- receiver
    (v_client_amt + v_client_fee),                                       -- brut (principal + frais)
    v_client_fee,
    v_client_amt,                                                        -- net = principal
    v_client_cur,
    v_cli_type, 'completed',
    CASE WHEN v_op = 'withdrawal'
         THEN 'Retrait cash chez ' || v_agent_name
         ELSE 'Dépôt cash chez ' || v_agent_name END,
    v_parent::text,
    v_base_meta || jsonb_build_object('side', 'client', 'counterparty_name', v_agent_name,
      'sender_name', CASE WHEN v_op='withdrawal' THEN 'Vous' ELSE v_agent_name END,
      'receiver_name', CASE WHEN v_op='withdrawal' THEN v_agent_name ELSE 'Vous' END),
    'acash_cli_' || v_parent::text,
    now()
  )
  ON CONFLICT (idempotency_key) DO NOTHING;

  -- ── LIGNE AGENT (mouvement principal en SA devise) ──
  INSERT INTO public.wallet_transactions
    (transaction_id, sender_user_id, receiver_user_id, amount, fee, net_amount, currency,
     transaction_type, status, description, reference_id, metadata, idempotency_key, created_at)
  VALUES (
    'acash_agt_' || v_parent::text,
    CASE WHEN v_op = 'withdrawal' THEN v_client ELSE v_agent_user END,   -- sender
    CASE WHEN v_op = 'withdrawal' THEN v_agent_user ELSE v_client END,   -- receiver
    v_agent_amt, 0, v_agent_amt, v_agent_cur,
    v_agt_type, 'completed',
    CASE WHEN v_op = 'withdrawal'
         THEN 'Retrait client ' || v_client_name
         ELSE 'Dépôt client ' || v_client_name END,
    v_parent::text,
    v_base_meta || jsonb_build_object('side', 'agent', 'counterparty_name', v_client_name,
      'sender_name', CASE WHEN v_op='withdrawal' THEN v_client_name ELSE 'Vous' END,
      'receiver_name', CASE WHEN v_op='withdrawal' THEN 'Vous' ELSE v_client_name END),
    'acash_agt_' || v_parent::text,
    now()
  )
  ON CONFLICT (idempotency_key) DO NOTHING;

  -- ── LIGNE COMMISSION (agent uniquement, liée par parent_tx_id) ──
  IF v_comm_paid AND COALESCE(v_comm_amt, 0) > 0 THEN
    INSERT INTO public.wallet_transactions
      (transaction_id, sender_user_id, receiver_user_id, amount, fee, net_amount, currency,
       transaction_type, status, description, reference_id, metadata, idempotency_key, created_at)
    VALUES (
      'acash_com_' || v_parent::text,
      NULL, v_agent_user,                          -- crédit reçu par l'agent (contrepartie = plateforme)
      v_comm_amt, 0, v_comm_amt, v_comm_cur,
      'commission', 'completed',
      'Commission cash — ' || CASE WHEN v_op='withdrawal' THEN 'retrait' ELSE 'dépôt' END,
      v_parent::text,
      v_base_meta || jsonb_build_object('side', 'agent', 'op_type', 'agent_cash_commission',
        'counterparty_name', v_client_name),
      'acash_com_' || v_parent::text,
      now()
    )
    ON CONFLICT (idempotency_key) DO NOTHING;
  END IF;

  EXCEPTION WHEN OTHERS THEN
    -- Log bruyant (surveillance PDG), puis on laisse l'opération d'argent réussir.
    BEGIN
      PERFORM public.agent_audit_log_safe('warning', 'agent_cash_history_emit_failed',
        jsonb_build_object('parent_tx_id', v_parent, 'op', v_op, 'err', SQLERRM));
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END;

  RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION public._acash_emit_wallet_history() FROM PUBLIC, anon, authenticated;

-- Trigger : fire une seule fois, quand result passe de NULL → non-NULL (opération complète).
DROP TRIGGER IF EXISTS trg_acash_emit_wallet_history ON public.agent_cash_operations;
CREATE TRIGGER trg_acash_emit_wallet_history
AFTER UPDATE OF result ON public.agent_cash_operations
FOR EACH ROW
WHEN (OLD.result IS NULL AND NEW.result IS NOT NULL)
EXECUTE FUNCTION public._acash_emit_wallet_history();

COMMENT ON FUNCTION public._acash_emit_wallet_history() IS
  'Émet les lignes wallet_transactions à deux faces (client + agent + commission liée par parent_tx_id) après complétion d''une opération agent-cash. Lecture seule des legs agent_cash_ledger — ne touche AUCUN solde ni flux. Atomique (même transaction que la RPC). Idempotent.';
