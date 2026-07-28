-- ============================================================================
-- ⚠️ NON APPLIQUÉE — livrée pour validation (mouvement d'argent réel).
-- Désactivation VOLONTAIRE d'un agent cash = solde de tout compte + sortie propre.
-- ============================================================================
-- Distincte de la SUSPENSION (cash_agent_suspended = punitif/temporaire) : ici
-- l'agent quitte le rôle proprement (départ, pas sanction). On ne désactive PAS
-- un agent qui détient encore de l'argent du système : c'est la FIN d'un solde de
-- tout compte, pas un booléen.
--
-- Décisions Thierno : lots = OPTION A (l'ex-agent GARDE ses 20 % différés → on ne
-- touche pas aux lots). Réactivation = uniquement via activate_cash_agent normal
-- (aucune route « réactiver » qui restaurerait l'ancien état).
-- ============================================================================

-- ── 1) Champs de sortie (distincts de la suspension cash_suspended_*) ────────
ALTER TABLE public.agents_management
  ADD COLUMN IF NOT EXISTS cash_deactivated_at timestamptz,
  ADD COLUMN IF NOT EXISTS cash_deactivated_by uuid;

-- ── 2) Nouveaux legs de sortie dans le CHECK du ledger ──────────────────────
ALTER TABLE public.agent_cash_ledger DROP CONSTRAINT IF EXISTS agent_cash_ledger_leg_check;
ALTER TABLE public.agent_cash_ledger ADD CONSTRAINT agent_cash_ledger_leg_check
  CHECK (leg = ANY (ARRAY[
    'client_debit','client_credit','client_fee_debit',
    'agent_wallet_debit','agent_wallet_credit','agent_float_credit','agent_float_debit',
    'pdg_fee_credit','pdg_commission_debit','agent_commission_credit','agent_commission_debit',
    'agent_personal_credit','float_merge_to_wallet','commission_merge_to_wallet',
    'commission_reversal_debit','commission_reversal_credit','deposit_agent_deferred_credit',
    'float_refund_on_exit','commission_payout_on_exit'   -- ⇐ solde de tout compte
  ]));

-- ── 3) Fonction atomique de désactivation ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.agent_cash_deactivate(
  p_agent_id uuid, p_actor uuid, p_reason text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_agent        RECORD;
  v_wallet_id    bigint; v_wallet_cur text;
  v_pdg_wallet   bigint; v_pdg_bal numeric;
  v_pending_tot  numeric := 0;
  v_float        numeric; v_comm numeric;
  v_parent       uuid := gen_random_uuid();
  v_p            RECORD; v_conv numeric;
  v_float_ref    numeric := 0; v_comm_ref numeric := 0; v_pending_paid numeric := 0;
BEGIN
  -- 1. Verrou + refus si déjà désactivé (idempotence : rejeu → état, rien refait).
  SELECT * INTO v_agent FROM public.agents_management WHERE id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AGENT_INTROUVABLE'; END IF;
  IF v_agent.cash_deactivated_at IS NOT NULL OR COALESCE(v_agent.cash_agent_enabled, false) = false THEN
    RETURN jsonb_build_object('already_deactivated', true, 'deactivated_at', v_agent.cash_deactivated_at);
  END IF;

  -- 2. Refus s'il existe une opération EN COURS (statut non terminal = result NULL).
  IF EXISTS (SELECT 1 FROM public.agent_cash_operations WHERE agent_id = p_agent_id AND result IS NULL) THEN
    RAISE EXCEPTION 'OPERATIONS_EN_COURS';
  END IF;

  -- Wallet perso (= wallet opérationnel de l'agent) + coffre PDG.
  SELECT wallet_id, currency INTO v_wallet_id, v_wallet_cur FROM public._acash_agent_wallet(v_agent.user_id);
  IF v_wallet_id IS NULL THEN RAISE EXCEPTION 'WALLET_AGENT_INTROUVABLE'; END IF;
  v_pdg_wallet := public.get_pdg_gnf_wallet_id();
  IF v_pdg_wallet IS NULL THEN RAISE EXCEPTION 'PDG_INTROUVABLE'; END IF;

  -- 3. PAYER les commissions EN ATTENTE avant la sortie — sinon BLOQUER (on ne sort
  --    pas un agent en lui devant de l'argent). Wallet PDG insuffisant → ROLLBACK.
  SELECT COALESCE(sum(amount),0) INTO v_pending_tot FROM public.agent_commission_pending
    WHERE agent_id = p_agent_id AND status = 'pending';
  IF v_pending_tot > 0 THEN
    SELECT balance INTO v_pdg_bal FROM public.wallets WHERE id = v_pdg_wallet FOR UPDATE;
    IF v_pdg_bal < v_pending_tot THEN
      RAISE EXCEPTION 'PDG_INSUFFISANT_POUR_SOLDE: manque % GNF pour payer % de commissions en attente',
        (v_pending_tot - v_pdg_bal), v_pending_tot;
    END IF;
    FOR v_p IN SELECT * FROM public.agent_commission_pending
               WHERE agent_id = p_agent_id AND status = 'pending' FOR UPDATE LOOP
      PERFORM public._acash_debit_wallet(v_pdg_wallet, v_p.amount, 'PDG_INSUFFISANT');
      v_conv := (public._acash_fx(v_p.amount, 'GNF', v_wallet_cur)->>'converted')::numeric;
      PERFORM public._acash_credit_wallet(v_wallet_id, v_conv);
      UPDATE public.agent_commission_pending SET status = 'resolved', resolved_by = p_actor, resolved_at = now()
        WHERE id = v_p.id;
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount, currency)
      VALUES (v_parent, 'deactivation', 'commission_payout_on_exit', p_agent_id, v_conv, v_wallet_cur);
      v_pending_paid := v_pending_paid + v_p.amount;
    END LOOP;
  END IF;

  -- 4. RESTITUER float + commissions (colonnes) vers le wallet perso (taux du jour).
  v_float := COALESCE(v_agent.cash_float_balance, 0);
  v_comm  := COALESCE(v_agent.cash_commission_balance, 0);
  IF v_float > 0 THEN
    v_conv := (public._acash_fx(v_float, 'GNF', v_wallet_cur)->>'converted')::numeric;
    PERFORM public._acash_credit_wallet(v_wallet_id, v_conv);
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount, currency)
    VALUES (v_parent, 'deactivation', 'float_refund_on_exit', p_agent_id, v_conv, v_wallet_cur);
    v_float_ref := v_float;
  END IF;
  IF v_comm > 0 THEN
    v_conv := (public._acash_fx(v_comm, 'GNF', v_wallet_cur)->>'converted')::numeric;
    PERFORM public._acash_credit_wallet(v_wallet_id, v_conv);
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount, currency)
    VALUES (v_parent, 'deactivation', 'commission_payout_on_exit', p_agent_id, v_conv, v_wallet_cur);
    v_comm_ref := v_comm;
  END IF;

  -- 5. LOTS = OPTION A : on NE TOUCHE PAS. Les lots restent actifs ; l'ex-agent
  --    continuera de recevoir ses 20 % différés sur son wallet (trigger de retrait).

  -- 6. Drapeaux de SORTIE (distincts de la suspension : cash_deactivated_* ≠ cash_suspended_*).
  UPDATE public.agents_management SET
    cash_agent_enabled   = false,
    cash_agent_active    = false,
    can_create_sub_agent = false,
    cash_float_balance   = 0,
    cash_commission_balance = 0,
    cash_deactivated_at  = now(),
    cash_deactivated_by  = p_actor,
    updated_at           = now()
  WHERE id = p_agent_id;

  -- 7. Audit (agent_audit_log_safe est une FONCTION, pas une table).
  PERFORM public.agent_audit_log_safe('info', 'agent_cash_deactivated', jsonb_build_object(
    'agent_id', p_agent_id, 'actor', p_actor, 'reason', p_reason,
    'float_refunded', v_float_ref, 'commission_refunded', v_comm_ref, 'pending_paid', v_pending_paid));

  RETURN jsonb_build_object('success', true, 'agent_id', p_agent_id,
    'float_refunded', v_float_ref, 'commission_refunded', v_comm_ref, 'pending_paid', v_pending_paid,
    'wallet_currency', v_wallet_cur, 'deactivated_at', now(),
    'lots_kept', true);   -- option A
END $$;

REVOKE ALL ON FUNCTION public.agent_cash_deactivate(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.agent_cash_deactivate(uuid, uuid, text) TO service_role;

-- Preview (lecture seule) pour l'écran de confirmation d'auto-désactivation :
-- « voici ce qui te sera restitué / ce que tu perds » AVANT de valider.
CREATE OR REPLACE FUNCTION public.agent_cash_deactivate_preview(p_agent_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object(
    'float_balance',      COALESCE(am.cash_float_balance, 0),
    'commission_balance', COALESCE(am.cash_commission_balance, 0),
    'pending_total',      COALESCE((SELECT sum(amount) FROM public.agent_commission_pending
                                    WHERE agent_id = p_agent_id AND status = 'pending'), 0),
    'active_lots',        COALESCE((SELECT count(*) FROM public.agent_cash_deposit_lots
                                    WHERE agent_id = p_agent_id AND amount_remaining > 0), 0),
    'lots_remaining_gnf', COALESCE((SELECT sum(amount_remaining) FROM public.agent_cash_deposit_lots
                                    WHERE agent_id = p_agent_id AND amount_remaining > 0), 0),
    'already_deactivated', (am.cash_deactivated_at IS NOT NULL)
  )
  FROM public.agents_management am WHERE am.id = p_agent_id;
$$;
REVOKE ALL ON FUNCTION public.agent_cash_deactivate_preview(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_deactivate_preview(uuid) TO authenticated, service_role;
