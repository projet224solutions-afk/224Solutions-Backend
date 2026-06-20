-- ============================================================================
-- ABONNEMENTS SERVICE — DURCISSEMENT « ULTRA BLINDÉ » (réf : logique vendeur).
-- ----------------------------------------------------------------------------
-- 1) purchase_service_subscription_atomic : validations défense-en-profondeur DANS
--    le RPC (propriété du service, plan actif, type cohérent, anti-surfacturation),
--    AVANT tout débit. Même atomicité que le vendeur (débit+écriture, rollback total).
-- 2) admin_set_service_plan_price_atomic : changement de prix PDG en UNE transaction
--    (historique + update), gardé admin/PDG. Remplace les 3 appels non atomiques.
-- Idempotent. Money RPC : REVOKE FROM PUBLIC.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.purchase_service_subscription_atomic(
  p_user_id uuid, p_amount numeric, p_idempotency_key text, p_description text,
  p_mode text, p_service_id uuid, p_plan_id uuid, p_cycle text, p_payment_method text,
  p_period_start timestamptz, p_period_end timestamptz, p_auto_renew boolean,
  p_metadata jsonb, p_current_sub_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_new_balance numeric; v_sub_id uuid;
  v_owner uuid; v_svc_type uuid; v_plan_active boolean; v_plan_type uuid;
  v_monthly numeric; v_yearly numeric; v_max_price numeric;
BEGIN
  -- ── VALIDATIONS (avant tout débit ; un RAISE annule toute la transaction) ──
  -- a) Le service existe et appartient à l'utilisateur.
  SELECT user_id, service_type_id INTO v_owner, v_svc_type
  FROM public.professional_services WHERE id = p_service_id;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'SERVICE_NOT_FOUND'; END IF;
  IF v_owner <> p_user_id THEN RAISE EXCEPTION 'NOT_SERVICE_OWNER'; END IF;

  -- b) Le plan existe, est actif, et son type est NULL (générique) ou = type du service.
  SELECT is_active, service_type_id, COALESCE(monthly_price_gnf,0), yearly_price_gnf
  INTO v_plan_active, v_plan_type, v_monthly, v_yearly
  FROM public.service_plans WHERE id = p_plan_id;
  IF v_plan_active IS NULL THEN RAISE EXCEPTION 'PLAN_NOT_FOUND'; END IF;
  IF NOT v_plan_active THEN RAISE EXCEPTION 'PLAN_INACTIVE'; END IF;
  IF v_plan_type IS NOT NULL AND v_plan_type <> v_svc_type THEN RAISE EXCEPTION 'PLAN_TYPE_MISMATCH'; END IF;

  -- c) Montant : non négatif et plafonné au prix MAX du plan (anti-surfacturation).
  IF p_amount IS NULL OR p_amount < 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
  v_max_price := COALESCE(v_yearly, v_monthly * 12) + 1; -- +1 = tolérance d'arrondi
  IF p_amount > v_max_price THEN RAISE EXCEPTION 'AMOUNT_TOO_HIGH'; END IF;

  -- ── DÉBIT + ÉCRITURE (atomique) ──
  v_new_balance := public.wallet_debit_internal(p_user_id, p_amount, p_description, p_idempotency_key);

  IF p_mode = 'switch' THEN
    UPDATE public.service_subscriptions
    SET plan_id = p_plan_id, updated_at = now(), metadata = p_metadata
    WHERE id = p_current_sub_id AND professional_service_id = p_service_id AND user_id = p_user_id
    RETURNING id INTO v_sub_id;
    IF v_sub_id IS NULL THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_FOUND'; END IF;
  ELSE
    UPDATE public.service_subscriptions
    SET status = 'expired', updated_at = now()
    WHERE professional_service_id = p_service_id AND user_id = p_user_id
      AND status IN ('active', 'trialing');

    INSERT INTO public.service_subscriptions (
      professional_service_id, user_id, plan_id, price_paid_gnf, billing_cycle, status,
      started_at, current_period_start, current_period_end, auto_renew, payment_method, metadata
    ) VALUES (
      p_service_id, p_user_id, p_plan_id, COALESCE(p_amount, 0), p_cycle, 'active',
      p_period_start, p_period_start, p_period_end, p_auto_renew, p_payment_method, p_metadata
    )
    RETURNING id INTO v_sub_id;
  END IF;

  RETURN jsonb_build_object('status', 'created', 'subscription_id', v_sub_id, 'new_balance', v_new_balance, 'mode', p_mode);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.purchase_service_subscription_atomic(uuid, numeric, text, text, text, uuid, uuid, text, text, timestamptz, timestamptz, boolean, jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.purchase_service_subscription_atomic(uuid, numeric, text, text, text, uuid, uuid, text, text, timestamptz, timestamptz, boolean, jsonb, uuid) TO service_role;

-- ── PDG : changement de prix d'un plan service, ATOMIQUE + gardé admin ──────
CREATE OR REPLACE FUNCTION public.admin_set_service_plan_price_atomic(
  p_plan_id uuid, p_new_price numeric, p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_old numeric;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'NOT_ADMIN'; END IF;
  IF p_new_price IS NULL OR p_new_price < 0 THEN RAISE EXCEPTION 'INVALID_PRICE'; END IF;

  SELECT monthly_price_gnf INTO v_old FROM public.service_plans WHERE id = p_plan_id FOR UPDATE;
  IF v_old IS NULL THEN RAISE EXCEPTION 'PLAN_NOT_FOUND'; END IF;

  INSERT INTO public.service_plan_price_history (plan_id, old_price, new_price, changed_by, reason)
  VALUES (p_plan_id, v_old, p_new_price, auth.uid(), p_reason);

  UPDATE public.service_plans SET monthly_price_gnf = p_new_price, updated_at = now() WHERE id = p_plan_id;

  RETURN jsonb_build_object('success', true, 'old_price', v_old, 'new_price', p_new_price);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_set_service_plan_price_atomic(uuid, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_set_service_plan_price_atomic(uuid, numeric, text) TO authenticated, service_role;

SELECT 'Abonnements service durcis : RPC achat validé (propriété/plan/anti-surfacturation) + changement de prix PDG atomique.' AS status;
