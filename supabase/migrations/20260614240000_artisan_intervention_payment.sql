-- ============================================================================
-- SERVICES ARTISANS — Phase 1b : PAIEMENT de l'intervention (acompte + solde) via wallet
-- ----------------------------------------------------------------------------
-- Le client paie l'artisan en 2 temps depuis son wallet, dans la MÊME transaction que
-- le débit (tout-ou-rien) : ACOMPTE à l'acceptation (défaut 30%) puis SOLDE à la
-- validation. La plateforme prélève sa commission (service_types.commission_rate, 5%).
-- Réutilise les primitives durcies : wallet_debit_internal (débit + idempotence),
-- credit_user_wallet_safe (crédit net artisan + commission PDG, conversion/AML).
-- REVOKE FROM PUBLIC → backend (service_role) uniquement. Idempotent / rejouable.
-- ============================================================================

-- ── 1) Colonnes de suivi du paiement ────────────────────────────────────────
ALTER TABLE public.artisan_interventions ADD COLUMN IF NOT EXISTS deposit_amount    numeric(12,2) NOT NULL DEFAULT 0;
ALTER TABLE public.artisan_interventions ADD COLUMN IF NOT EXISTS deposit_paid_at   timestamptz;
ALTER TABLE public.artisan_interventions ADD COLUMN IF NOT EXISTS balance_paid_at   timestamptz;
ALTER TABLE public.artisan_interventions ADD COLUMN IF NOT EXISTS amount_paid       numeric(12,2) NOT NULL DEFAULT 0;
ALTER TABLE public.artisan_interventions ADD COLUMN IF NOT EXISTS commission_total  numeric(12,2) NOT NULL DEFAULT 0;

-- ── Helper interne : règle un montant client → artisan (net) + commission PDG ─
-- (Dans la transaction de l'appelant. Lève une exception → ROLLBACK total.)
CREATE OR REPLACE FUNCTION public.artisan_settle_payment_internal(
  p_intervention_id uuid, p_client uuid, p_artisan uuid, p_service_type text,
  p_amount numeric, p_idempotency_key text, p_label text
) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rate numeric; v_commission numeric; v_net numeric; v_pdg uuid;
BEGIN
  IF COALESCE(p_amount,0) <= 0 THEN RETURN 0; END IF;

  SELECT COALESCE(commission_rate, 5) INTO v_rate FROM public.service_types WHERE code = p_service_type;
  v_commission := round(p_amount * COALESCE(v_rate,5) / 100.0);
  v_net        := p_amount - v_commission;
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  -- 1) Débit client (idempotence forte : 1 paiement par clé) → ROLLBACK si solde/blocage.
  PERFORM public.wallet_debit_internal(p_client, p_amount, p_label, p_idempotency_key);
  -- 2) Crédit net à l'artisan.
  PERFORM public.credit_user_wallet_safe(p_artisan, v_net, 'GNF', 'artisan_payment', p_intervention_id::text);
  -- 3) Commission plateforme au PDG.
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'artisan_commission', p_intervention_id::text);
  END IF;

  UPDATE public.artisan_interventions
    SET amount_paid = amount_paid + p_amount, commission_total = commission_total + v_commission
    WHERE id = p_intervention_id;

  RETURN v_commission;
END;
$$;

-- ── 2) RPC : ACOMPTE (client) — défaut 30% du devis ─────────────────────────
CREATE OR REPLACE FUNCTION public.pay_artisan_deposit_atomic(
  p_intervention_id uuid, p_actor_user_id uuid, p_deposit_pct numeric DEFAULT 30
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE i public.artisan_interventions%ROWTYPE; q public.artisan_quotes%ROWTYPE; v_amount numeric; v_pct numeric;
BEGIN
  SELECT * INTO i FROM public.artisan_interventions WHERE id = p_intervention_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INTERVENTION_NOT_FOUND'; END IF;
  IF p_actor_user_id <> i.client_id THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;
  IF i.deposit_paid_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'already', true, 'amount_paid', i.amount_paid);
  END IF;

  SELECT * INTO q FROM public.artisan_quotes WHERE id = i.quote_id;
  IF NOT FOUND OR COALESCE(q.total_ttc,0) <= 0 THEN RAISE EXCEPTION 'QUOTE_INVALID'; END IF;

  v_pct    := LEAST(GREATEST(COALESCE(p_deposit_pct,30), 0), 100);
  v_amount := round(q.total_ttc * v_pct / 100.0);

  PERFORM public.artisan_settle_payment_internal(
    i.id, i.client_id, i.artisan_id, i.service_type, v_amount,
    'artisan-deposit-' || i.id::text, 'Acompte intervention ' || i.service_type);

  UPDATE public.artisan_interventions
    SET deposit_amount = v_amount, deposit_paid_at = now()
    WHERE id = i.id;

  RETURN jsonb_build_object('success', true, 'deposit', v_amount);
END;
$$;

-- ── 3) RPC : SOLDE (client) — après validation de l'intervention ─────────────
CREATE OR REPLACE FUNCTION public.pay_artisan_balance_atomic(
  p_intervention_id uuid, p_actor_user_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE i public.artisan_interventions%ROWTYPE; q public.artisan_quotes%ROWTYPE; v_balance numeric;
BEGIN
  SELECT * INTO i FROM public.artisan_interventions WHERE id = p_intervention_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INTERVENTION_NOT_FOUND'; END IF;
  IF p_actor_user_id <> i.client_id THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;
  IF i.status NOT IN ('completed','validated') THEN RAISE EXCEPTION 'NOT_COMPLETED'; END IF;
  IF i.balance_paid_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'already', true, 'amount_paid', i.amount_paid);
  END IF;

  SELECT * INTO q FROM public.artisan_quotes WHERE id = i.quote_id;
  IF NOT FOUND OR COALESCE(q.total_ttc,0) <= 0 THEN RAISE EXCEPTION 'QUOTE_INVALID'; END IF;

  v_balance := q.total_ttc - i.amount_paid;
  IF v_balance <= 0 THEN
    UPDATE public.artisan_interventions SET balance_paid_at = now() WHERE id = i.id;
    RETURN jsonb_build_object('success', true, 'balance', 0, 'note', 'already_settled');
  END IF;

  PERFORM public.artisan_settle_payment_internal(
    i.id, i.client_id, i.artisan_id, i.service_type, v_balance,
    'artisan-balance-' || i.id::text, 'Solde intervention ' || i.service_type);

  UPDATE public.artisan_interventions SET balance_paid_at = now() WHERE id = i.id;

  RETURN jsonb_build_object('success', true, 'balance', v_balance);
END;
$$;

-- ── 4) Durcissement : REVOKE FROM PUBLIC, backend (service_role) uniquement ───
REVOKE EXECUTE ON FUNCTION public.artisan_settle_payment_internal(uuid, uuid, uuid, text, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.artisan_settle_payment_internal(uuid, uuid, uuid, text, numeric, text, text) TO service_role;
REVOKE EXECUTE ON FUNCTION public.pay_artisan_deposit_atomic(uuid, uuid, numeric) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.pay_artisan_deposit_atomic(uuid, uuid, numeric) TO service_role;
REVOKE EXECUTE ON FUNCTION public.pay_artisan_balance_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.pay_artisan_balance_atomic(uuid, uuid) TO service_role;

SELECT 'Paiement intervention artisan créé (acompte/solde atomiques + commission PDG, REVOKE PUBLIC).' AS status;
