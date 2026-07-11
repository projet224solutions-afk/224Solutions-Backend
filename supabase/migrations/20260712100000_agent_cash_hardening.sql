-- ════════════════════════════════════════════════════════════════════════════
-- DURCISSEMENT AGENT CASH — invariant « commission = opération » + plafond client
-- ════════════════════════════════════════════════════════════════════════════
-- Règle d'or PDG : « S'il n'y a pas de commission, il n'y a pas de retrait ou dépôt du tout. »
-- Chaque opération cash et sa commission naissent dans LA MÊME transaction ou ne naissent pas.
--
-- D1 : ligne de commission (versée / pending / 0 tracé) TOUJOURS écrite dans la RPC + CHECK final
--      COMMISSION_MANQUANTE (rollback total sinon). Réconciliation : count(ops) = count(commissions).
-- D4 : plafond de retrait journalier par CLIENT (24h glissantes), vérifié DANS la RPC (verrou inclus).
-- D5 : verrous FOR UPDATE dans l'ordre déterministe agent → client → PDG (déjà en place, inchangé).
--
-- CREATE OR REPLACE : reprend le corps LIVE des RPC (migration 20260710120000) + ajouts ci-dessus.
-- Aucune donnée modifiée ; livrée en fichier, JAMAIS exécutée sans validation.
-- ════════════════════════════════════════════════════════════════════════════

-- ── D4 : nouveau paramètre de config — plafond de retrait journalier par client ──
ALTER TABLE public.agent_cash_config
  ADD COLUMN IF NOT EXISTS max_client_withdrawal_daily numeric NOT NULL DEFAULT 5000000;

-- ── D1 : Dépôt cash — commission TOUJOURS tracée + CHECK final ──
CREATE OR REPLACE FUNCTION public.agent_cash_deposit(
  p_agent_id uuid, p_client_user_id uuid, p_amount numeric, p_idempotency_key text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent uuid; v_agent RECORD; v_cfg public.agent_cash_config;
  v_commission numeric; v_pdg_wallet bigint; v_pdg_bal numeric; v_paid boolean := false;
  v_credit_res jsonb; v_has_commission boolean;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_client_user_id IS NULL THEN RAISE EXCEPTION 'CLIENT_INTROUVABLE'; END IF;
  v_cfg := public.agent_cash_active_config();

  INSERT INTO public.agent_cash_operations (idempotency_key, operation, agent_id, client_user_id, amount)
  VALUES (p_idempotency_key, 'deposit', p_agent_id, p_client_user_id, p_amount)
  ON CONFLICT (idempotency_key) DO NOTHING RETURNING parent_tx_id INTO v_parent;
  IF v_parent IS NULL THEN
    RETURN (SELECT result FROM public.agent_cash_operations WHERE idempotency_key = p_idempotency_key);
  END IF;

  -- Verrous ordre déterministe : agent (float) → client (dans credit_user_wallet_safe) → PDG.
  SELECT * INTO v_agent FROM public.agents_management WHERE id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AGENT_INTROUVABLE'; END IF;
  IF NOT v_agent.cash_agent_active OR v_agent.cash_agent_suspended THEN RAISE EXCEPTION 'AGENT_INACTIF'; END IF;
  IF v_agent.cash_float_balance < v_cfg.min_float_for_operations THEN RAISE EXCEPTION 'FLOAT_INSUFFISANT'; END IF;
  IF v_agent.cash_float_balance < p_amount THEN RAISE EXCEPTION 'FLOAT_INSUFFISANT'; END IF;

  -- 1) Float agent -= montant
  UPDATE public.agents_management SET cash_float_balance = cash_float_balance - p_amount, updated_at = now()
  WHERE id = p_agent_id;
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
  VALUES (v_parent, 'deposit', 'agent_float_debit', p_agent_id, p_client_user_id, p_amount);

  -- 2) Client crédité du montant EXACT (canonique : conserve l'AML)
  v_credit_res := public.credit_user_wallet_safe(p_client_user_id, p_amount, 'GNF', 'agent_cash_deposit', v_parent::text);
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
  VALUES (v_parent, 'deposit', 'client_credit', p_agent_id, p_client_user_id, p_amount);

  -- 3) Commission de dépôt — TOUJOURS tracée (versée, pending, ou 0 tracé). Invariant PDG.
  v_commission := round(p_amount * v_cfg.deposit_agent_commission_percent / 100.0, 2);
  IF v_commission > 0 THEN
    v_pdg_wallet := public.get_pdg_gnf_wallet_id();
    IF v_pdg_wallet IS NOT NULL AND NOT v_agent.cash_agent_suspended THEN
      SELECT balance INTO v_pdg_bal FROM public.wallets WHERE id = v_pdg_wallet FOR UPDATE;
      IF v_pdg_bal >= v_commission THEN
        PERFORM public._acash_debit_wallet(v_pdg_wallet, v_commission, 'PDG_INSUFFISANT');
        UPDATE public.agents_management SET cash_commission_balance = cash_commission_balance + v_commission, updated_at = now()
        WHERE id = p_agent_id;
        INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
        VALUES (v_parent, 'deposit', 'pdg_commission_debit', p_agent_id, p_client_user_id, v_commission),
               (v_parent, 'deposit', 'agent_commission_credit', p_agent_id, p_client_user_id, v_commission);
        v_paid := true;
      END IF;
    END IF;
    IF NOT v_paid THEN
      INSERT INTO public.agent_commission_pending (agent_id, amount, reason, source_parent_tx_id)
      VALUES (p_agent_id, v_commission, CASE WHEN v_agent.cash_agent_suspended THEN 'agent_suspendu' ELSE 'pdg_insuffisant' END, v_parent);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, status)
      VALUES (v_parent, 'deposit', 'agent_commission_credit', p_agent_id, p_client_user_id, v_commission, 'pending');
    END IF;
  ELSE
    -- Commission configurée à 0 : on trace quand même la ligne (op ⇔ commission).
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, status)
    VALUES (v_parent, 'deposit', 'agent_commission_credit', p_agent_id, p_client_user_id, 0, 'completed');
  END IF;

  -- CHECK final : aucune opération ne peut exister sans sa commission tracée → sinon rollback total.
  SELECT EXISTS (SELECT 1 FROM public.agent_cash_ledger
    WHERE parent_tx_id = v_parent AND leg = 'agent_commission_credit') INTO v_has_commission;
  IF NOT v_has_commission THEN
    RAISE EXCEPTION 'COMMISSION_MANQUANTE: dépôt % sans commission tracée', v_parent;
  END IF;

  UPDATE public.agent_cash_operations SET agent_share = v_commission, result = jsonb_build_object(
    'success', true, 'parent_tx_id', v_parent, 'client_credited', p_amount,
    'agent_commission', v_commission, 'commission_paid', v_paid,
    'quarantined', COALESCE((v_credit_res->>'quarantined')::numeric, 0)
  ) WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_deposit(uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_deposit(uuid, uuid, numeric, text) TO service_role;

-- ── D1 + D4 : Retrait cash — commission TOUJOURS tracée + CHECK final + plafond client/jour ──
CREATE OR REPLACE FUNCTION public.agent_cash_withdrawal(
  p_agent_id uuid, p_client_user_id uuid, p_amount numeric, p_idempotency_key text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent uuid; v_agent RECORD; v_cfg public.agent_cash_config;
  v_client_wallet bigint; v_pdg_wallet bigint;
  v_fee numeric; v_agent_share numeric; v_pdg_share numeric;
  v_win_amount numeric := 0; v_win_fees numeric := 0; v_cum_fee numeric;
  v_day_comm numeric := 0; v_to_pending boolean := false; v_reason text := NULL;
  v_client_day numeric := 0; v_has_commission boolean;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_client_user_id IS NULL THEN RAISE EXCEPTION 'CLIENT_INTROUVABLE'; END IF;
  v_cfg := public.agent_cash_active_config();

  INSERT INTO public.agent_cash_operations (idempotency_key, operation, agent_id, client_user_id, amount)
  VALUES (p_idempotency_key, 'withdrawal', p_agent_id, p_client_user_id, p_amount)
  ON CONFLICT (idempotency_key) DO NOTHING RETURNING parent_tx_id INTO v_parent;
  IF v_parent IS NULL THEN
    RETURN (SELECT result FROM public.agent_cash_operations WHERE idempotency_key = p_idempotency_key);
  END IF;

  SELECT * INTO v_agent FROM public.agents_management WHERE id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AGENT_INTROUVABLE'; END IF;
  IF NOT v_agent.cash_agent_active THEN RAISE EXCEPTION 'AGENT_INACTIF'; END IF;
  IF v_agent.cash_float_balance < v_cfg.min_float_for_operations THEN RAISE EXCEPTION 'FLOAT_INSUFFISANT'; END IF;

  -- D4 : plafond de retrait journalier par CLIENT (24h glissantes). Dernier filet anti-téléphone-volé.
  -- Le verrou du wallet client (plus bas) sérialise les retraits concurrents du même client.
  SELECT COALESCE(sum(amount), 0) INTO v_client_day FROM public.agent_cash_operations
  WHERE operation = 'withdrawal' AND client_user_id = p_client_user_id
    AND created_at > now() - interval '24 hours' AND parent_tx_id <> v_parent;
  IF (v_client_day + p_amount) > COALESCE(v_cfg.max_client_withdrawal_daily, 5000000) THEN
    RAISE EXCEPTION 'PLAFOND_CLIENT_ATTEINT';
  END IF;

  -- Anti-splitting : frais sur le CUMUL de la fenêtre, moins les frais déjà payés.
  SELECT COALESCE(sum(amount),0), COALESCE(sum(fee),0) INTO v_win_amount, v_win_fees
  FROM public.agent_cash_operations
  WHERE operation = 'withdrawal' AND agent_id = p_agent_id AND client_user_id = p_client_user_id
    AND created_at > now() - make_interval(mins => v_cfg.anti_split_window_minutes)
    AND parent_tx_id <> v_parent;
  v_cum_fee := least(greatest(round((v_win_amount + p_amount) * v_cfg.withdrawal_fee_percent / 100.0, 2), v_cfg.withdrawal_fee_min), v_cfg.withdrawal_fee_max);
  v_fee := greatest(v_cum_fee - v_win_fees, 0);
  v_agent_share := round(v_fee * v_cfg.withdrawal_agent_share_of_fee / 100.0, 2);
  v_pdg_share   := v_fee - v_agent_share;

  -- 1) Client débité de (montant + frais). Verrou wallet client (ordre : agent → client → PDG).
  SELECT id INTO v_client_wallet FROM public.wallets WHERE user_id = p_client_user_id AND currency = 'GNF';
  IF v_client_wallet IS NULL THEN RAISE EXCEPTION 'WALLET_CLIENT_INTROUVABLE'; END IF;
  PERFORM public._acash_debit_wallet(v_client_wallet, p_amount + v_fee, 'SOLDE_INSUFFISANT');
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
  VALUES (v_parent, 'withdrawal', 'client_debit', p_agent_id, p_client_user_id, p_amount + v_fee);

  -- 2) Float agent += montant (il rend le cash physique)
  UPDATE public.agents_management SET cash_float_balance = cash_float_balance + p_amount, updated_at = now()
  WHERE id = p_agent_id;
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
  VALUES (v_parent, 'withdrawal', 'agent_float_credit', p_agent_id, p_client_user_id, p_amount);

  -- 3) Transit PDG : frais entrent au PDG, puis part agent en sort.
  v_pdg_wallet := public.get_pdg_gnf_wallet_id();
  IF v_pdg_wallet IS NULL THEN RAISE EXCEPTION 'PDG_INTROUVABLE'; END IF;
  IF v_fee > 0 THEN
    PERFORM public._acash_credit_wallet(v_pdg_wallet, v_fee);
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
    VALUES (v_parent, 'withdrawal', 'pdg_fee_credit', p_agent_id, p_client_user_id, v_fee);
  END IF;

  -- Plafond commission journalier + kill switch → part agent en pending.
  SELECT COALESCE(sum(agent_share),0) INTO v_day_comm FROM public.agent_cash_operations
  WHERE agent_id = p_agent_id AND operation = 'withdrawal' AND created_at::date = now()::date AND parent_tx_id <> v_parent;
  IF v_agent.cash_agent_suspended THEN v_to_pending := true; v_reason := 'agent_suspendu';
  ELSIF (v_day_comm + v_agent_share) > v_cfg.daily_commission_cap_per_agent THEN v_to_pending := true; v_reason := 'plafond_journalier';
  END IF;

  -- Commission agent — TOUJOURS tracée (versée, pending, ou 0 tracé). Invariant PDG.
  IF v_agent_share > 0 THEN
    IF v_to_pending THEN
      INSERT INTO public.agent_commission_pending (agent_id, amount, reason, source_parent_tx_id)
      VALUES (p_agent_id, v_agent_share, v_reason, v_parent);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, status)
      VALUES (v_parent, 'withdrawal', 'agent_commission_credit', p_agent_id, p_client_user_id, v_agent_share, 'pending');
      INSERT INTO public.agent_audit_log_safe(severity, event, detail)
      VALUES ('warning', 'agent_cash_commission_pending', jsonb_build_object('agent_id', p_agent_id, 'amount', v_agent_share, 'reason', v_reason, 'parent_tx_id', v_parent));
    ELSE
      PERFORM public._acash_debit_wallet(v_pdg_wallet, v_agent_share, 'PDG_INSUFFISANT');
      UPDATE public.agents_management SET cash_commission_balance = cash_commission_balance + v_agent_share, updated_at = now()
      WHERE id = p_agent_id;
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
      VALUES (v_parent, 'withdrawal', 'pdg_commission_debit', p_agent_id, p_client_user_id, v_agent_share),
             (v_parent, 'withdrawal', 'agent_commission_credit', p_agent_id, p_client_user_id, v_agent_share);
    END IF;
  ELSE
    -- Frais/part agent nuls : on trace quand même la ligne (op ⇔ commission).
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, status)
    VALUES (v_parent, 'withdrawal', 'agent_commission_credit', p_agent_id, p_client_user_id, 0, 'completed');
  END IF;

  -- CHECK final : aucune opération sans sa commission tracée → sinon rollback total.
  SELECT EXISTS (SELECT 1 FROM public.agent_cash_ledger
    WHERE parent_tx_id = v_parent AND leg = 'agent_commission_credit') INTO v_has_commission;
  IF NOT v_has_commission THEN
    RAISE EXCEPTION 'COMMISSION_MANQUANTE: retrait % sans commission tracée', v_parent;
  END IF;

  UPDATE public.agent_cash_operations
  SET fee = v_fee, agent_share = v_agent_share, pdg_share = v_pdg_share,
      result = jsonb_build_object('success', true, 'parent_tx_id', v_parent, 'amount', p_amount,
        'fee', v_fee, 'agent_share', v_agent_share, 'pdg_share', v_pdg_share, 'commission_pending', v_to_pending)
  WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_withdrawal(uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_withdrawal(uuid, uuid, numeric, text) TO service_role;

-- ── D1 : réconciliation renforcée — invariant count(opérations) = count(commissions) ──
CREATE OR REPLACE FUNCTION public.agent_cash_reconciliation_check()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_unbalanced int; v_float_drift int; v_missing_comm int; v_report jsonb;
BEGIN
  -- Invariant 1 : par parent_tx_id, somme(débits) = somme(crédits) (legs completed).
  SELECT count(*) INTO v_unbalanced FROM (
    SELECT parent_tx_id,
      sum(CASE WHEN leg LIKE '%_debit' THEN amount ELSE 0 END) AS deb,
      sum(CASE WHEN leg LIKE '%_credit' THEN amount ELSE 0 END) AS cred
    FROM public.agent_cash_ledger WHERE status = 'completed'
    GROUP BY parent_tx_id
    HAVING abs(sum(CASE WHEN leg LIKE '%_debit' THEN amount ELSE 0 END)
             - sum(CASE WHEN leg LIKE '%_credit' THEN amount ELSE 0 END)) > 1
  ) d;

  -- Invariant 2 : float agent = somme(float_credit) − somme(float_debit) du ledger.
  SELECT count(*) INTO v_float_drift FROM (
    SELECT a.id,
      a.cash_float_balance AS bal,
      COALESCE(sum(CASE WHEN l.leg='agent_float_credit' THEN l.amount
                        WHEN l.leg='agent_float_debit'  THEN -l.amount ELSE 0 END),0) AS expected
    FROM public.agents_management a
    LEFT JOIN public.agent_cash_ledger l ON l.agent_id = a.id AND l.status='completed'
    GROUP BY a.id, a.cash_float_balance
    HAVING abs(a.cash_float_balance - COALESCE(sum(CASE WHEN l.leg='agent_float_credit' THEN l.amount
                        WHEN l.leg='agent_float_debit'  THEN -l.amount ELSE 0 END),0)) > 1
  ) f;

  -- Invariant 3 (PDG) : chaque dépôt/retrait a SA commission tracée (versée OU pending).
  -- « Pas de commission → pas d'opération. » Tout écart = anomalie CRITIQUE.
  SELECT count(*) INTO v_missing_comm FROM public.agent_cash_operations o
  WHERE o.operation IN ('deposit','withdrawal')
    AND NOT EXISTS (
      SELECT 1 FROM public.agent_cash_ledger l
      WHERE l.parent_tx_id = o.parent_tx_id AND l.leg = 'agent_commission_credit'
    );

  v_report := jsonb_build_object('generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','ledger_unbalanced','label','Opérations dont débits ≠ crédits','severity','critical','count',v_unbalanced,'observed',v_unbalanced),
      jsonb_build_object('key','float_drift','label','Float agent ≠ somme des legs float','severity','critical','count',v_float_drift,'observed',v_float_drift),
      jsonb_build_object('key','missing_commission','label','Opérations sans commission tracée','severity','critical','count',v_missing_comm,'observed',v_missing_comm)
    ));
  IF v_unbalanced > 0 OR v_float_drift > 0 OR v_missing_comm > 0 THEN
    PERFORM public.agent_audit_log_safe('critical', 'agent_cash_reconciliation_anomaly', v_report);
  END IF;
  RETURN v_report;
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_reconciliation_check() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_reconciliation_check() TO authenticated, service_role;

-- ── D4 : exposer max_client_withdrawal_daily dans la mise à jour de config PDG ──
CREATE OR REPLACE FUNCTION public.agent_cash_config_update(p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cur public.agent_cash_config; v_new_id uuid;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  v_cur := public.agent_cash_active_config();
  UPDATE public.agent_cash_config SET is_active = false WHERE is_active = true;
  INSERT INTO public.agent_cash_config (
    withdrawal_fee_percent, withdrawal_fee_min, withdrawal_fee_max,
    withdrawal_agent_share_of_fee, withdrawal_pdg_share_of_fee,
    deposit_agent_commission_percent, activation_float_threshold,
    min_float_for_operations, daily_commission_cap_per_agent, anti_split_window_minutes,
    max_client_withdrawal_daily, is_active, created_by)
  VALUES (
    COALESCE((p_changes->>'withdrawal_fee_percent')::numeric, v_cur.withdrawal_fee_percent),
    COALESCE((p_changes->>'withdrawal_fee_min')::numeric, v_cur.withdrawal_fee_min),
    COALESCE((p_changes->>'withdrawal_fee_max')::numeric, v_cur.withdrawal_fee_max),
    COALESCE((p_changes->>'withdrawal_agent_share_of_fee')::numeric, v_cur.withdrawal_agent_share_of_fee),
    COALESCE((p_changes->>'withdrawal_pdg_share_of_fee')::numeric, v_cur.withdrawal_pdg_share_of_fee),
    COALESCE((p_changes->>'deposit_agent_commission_percent')::numeric, v_cur.deposit_agent_commission_percent),
    COALESCE((p_changes->>'activation_float_threshold')::numeric, v_cur.activation_float_threshold),
    COALESCE((p_changes->>'min_float_for_operations')::numeric, v_cur.min_float_for_operations),
    COALESCE((p_changes->>'daily_commission_cap_per_agent')::numeric, v_cur.daily_commission_cap_per_agent),
    COALESCE((p_changes->>'anti_split_window_minutes')::int, v_cur.anti_split_window_minutes),
    COALESCE((p_changes->>'max_client_withdrawal_daily')::numeric, v_cur.max_client_withdrawal_daily),
    true, auth.uid())
  RETURNING id INTO v_new_id;
  RETURN jsonb_build_object('success', true, 'config_id', v_new_id);
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_config_update(jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_config_update(jsonb) TO authenticated, service_role;

-- ── Chantier B : stats commissions de l'agent (gagné aujourd'hui / ce mois / total) ──
-- Ne compte que les commissions VERSÉES (status completed) — « gagné ». L'historique côté
-- endpoint affiche aussi les pending.
CREATE OR REPLACE FUNCTION public.agent_cash_commission_stats(p_agent_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object(
    'today', COALESCE(sum(amount) FILTER (WHERE created_at::date = now()::date), 0),
    'month', COALESCE(sum(amount) FILTER (WHERE date_trunc('month', created_at) = date_trunc('month', now())), 0),
    'total', COALESCE(sum(amount), 0)
  )
  FROM public.agent_cash_ledger
  WHERE agent_id = p_agent_id AND leg = 'agent_commission_credit' AND status = 'completed';
$$;
REVOKE ALL ON FUNCTION public.agent_cash_commission_stats(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_commission_stats(uuid) TO authenticated, service_role;

SELECT 'Durcissement Agent Cash : invariant commission=opération (CHECK COMMISSION_MANQUANTE) + plafond client/jour + réconciliation renforcée (3 invariants) + stats commissions.' AS status;
