-- ═══════════════════════════════════════════════════════════════════════════
-- RATTRAPAGE des commissions agent perdues par le bug des décimales (EUR/USD/SLE…).
-- Idempotent : une jambe ledger `commission_backfill` par opération → aucun double crédit
-- au re-run. Crédite via le flux NORMAL (débit coffre PDG → crédit wallet agent).
-- Migration NOUVELLE. Cible : dépôts/retraits en devise DÉCIMALE, agent_share=0, montant>0,
-- dont la commission recalculée (règles EN VIGUEUR) est > 0.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.agent_cash_backfill_decimal_commission()
RETURNS TABLE(parent_tx_id uuid, operation text, client_ccy text, due_gnf numeric, credited boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r record; v_rules jsonb; v_client_cur text; v_dec int;
  v_basis_fee numeric; v_fee_gnf numeric; v_due_gnf numeric;
  v_pdg_wallet bigint; v_aw_id bigint; v_aw_cur text; v_comm_agent numeric; v_pdg_bal numeric;
BEGIN
  v_pdg_wallet := public.get_pdg_gnf_wallet_id();
  IF v_pdg_wallet IS NULL THEN RAISE EXCEPTION 'PDG_INTROUVABLE'; END IF;

  FOR r IN
    SELECT o.parent_tx_id AS ptx, o.operation AS op, o.amount AS amt, o.agent_id AS aid,
      (SELECT l.currency FROM public.agent_cash_ledger l WHERE l.parent_tx_id = o.parent_tx_id AND l.leg='client_credit' LIMIT 1) AS ccur
    FROM public.agent_cash_operations o
    WHERE o.agent_share = 0 AND o.amount > 0 AND o.operation IN ('deposit','withdrawal')
  LOOP
    v_client_cur := r.ccur;
    CONTINUE WHEN v_client_cur IS NULL;
    v_dec := public._ccy_decimals(v_client_cur);
    CONTINUE WHEN v_dec = 0;  -- devises 0-décimale : jamais victimes du bug
    -- Idempotence : l'UPDATE agent_share ci-dessous sort l'op du filtre `agent_share=0` au re-run.

    v_rules := public._acash_currency_rules(v_client_cur);
    -- Base du frais selon l'opération (dépôt = frais de RETRAIT attendu ; retrait = frais de retrait).
    v_basis_fee := least(greatest(
      round(r.amt * (v_rules->>'w_pct')::numeric / 100.0, v_dec),
      (v_rules->>'w_min')::numeric), (v_rules->>'w_max')::numeric);
    v_fee_gnf := (public._acash_fx(v_basis_fee, v_client_cur, 'GNF')->>'converted')::numeric;
    v_due_gnf := round(v_fee_gnf * (v_rules->>(CASE WHEN r.op='deposit' THEN 'd_share' ELSE 'w_share' END))::numeric / 100.0);

    parent_tx_id := r.ptx; operation := r.op; client_ccy := v_client_cur; due_gnf := v_due_gnf; credited := false;
    IF v_due_gnf <= 0 THEN RETURN NEXT; CONTINUE; END IF;

    -- Wallet agent (devise réelle). ABSENT → on met en PENDING (versé quand le wallet existera,
    -- via le flux différé existant agent_cash_release_pending) plutôt que de créditer dans le vide.
    SELECT wallet_id, currency INTO v_aw_id, v_aw_cur FROM public._acash_agent_wallet(r.aid);

    IF v_aw_id IS NULL THEN
      INSERT INTO public.agent_commission_pending (agent_id, amount, reason, source_parent_tx_id)
      VALUES (r.aid, v_due_gnf, 'rattrapage_decimales', r.ptx);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount, currency, status)
      VALUES (r.ptx, r.op, 'agent_commission_credit', r.aid, v_due_gnf, 'GNF', 'pending');
      UPDATE public.agent_cash_operations SET agent_share = v_due_gnf WHERE agent_cash_operations.parent_tx_id = r.ptx;
      credited := true; -- rattrapé (en attente de wallet) — idempotent
      RETURN NEXT; CONTINUE;
    END IF;

    v_comm_agent := (public._acash_fx(v_due_gnf, 'GNF', v_aw_cur)->>'converted')::numeric;
    SELECT balance INTO v_pdg_bal FROM public.wallets WHERE id = v_pdg_wallet FOR UPDATE;
    IF v_pdg_bal < v_due_gnf THEN RETURN NEXT; CONTINUE; END IF; -- coffre insuffisant → laissé pour re-run

    PERFORM public._acash_debit_wallet(v_pdg_wallet, v_due_gnf, 'PDG_INSUFFISANT');
    PERFORM public._acash_credit_wallet(v_aw_id, v_comm_agent);
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount, currency)
    VALUES (r.ptx, r.op, 'agent_commission_credit', r.aid, v_comm_agent, v_aw_cur);
    UPDATE public.agent_cash_operations SET agent_share = v_due_gnf WHERE agent_cash_operations.parent_tx_id = r.ptx;
    credited := true;
    RETURN NEXT;
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.agent_cash_backfill_decimal_commission() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.agent_cash_backfill_decimal_commission() TO service_role;
