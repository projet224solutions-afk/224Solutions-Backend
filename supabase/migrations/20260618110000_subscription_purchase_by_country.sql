-- ============================================================================
-- 🌍 ACHAT ABONNEMENT SERVICE — PRIX IMPOSÉ PAR PAYS VERROUILLÉ.
-- ----------------------------------------------------------------------------
-- Étend purchase_service_subscription_atomic (MÊME signature → AUCUNE nouvelle surcharge,
-- donc aucun drift) : si une grille subscription_prices existe pour le pays verrouillé du
-- client × service × plan, le SERVEUR impose CE prix (jamais le prix client p_amount).
-- Repli : si pas de grille → ancien comportement (plafond GNF du plan).
--
-- Atomique : débit + écriture en 1 transaction, rollback total sur RAISE. Idempotent
-- (clé d'idempotence portée par wallet_debit_internal). REVOKE FROM PUBLIC.
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
  v_svc_code text; v_plan_name text; v_grid jsonb; v_amount numeric; v_metadata jsonb;
BEGIN
  -- ── VALIDATIONS (avant tout débit ; un RAISE annule toute la transaction) ──
  SELECT user_id, service_type_id INTO v_owner, v_svc_type
  FROM public.professional_services WHERE id = p_service_id;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'SERVICE_NOT_FOUND'; END IF;
  IF v_owner <> p_user_id THEN RAISE EXCEPTION 'NOT_SERVICE_OWNER'; END IF;

  SELECT is_active, service_type_id, COALESCE(monthly_price_gnf,0), yearly_price_gnf, name
  INTO v_plan_active, v_plan_type, v_monthly, v_yearly, v_plan_name
  FROM public.service_plans WHERE id = p_plan_id;
  IF v_plan_active IS NULL THEN RAISE EXCEPTION 'PLAN_NOT_FOUND'; END IF;
  IF NOT v_plan_active THEN RAISE EXCEPTION 'PLAN_INACTIVE'; END IF;
  IF v_plan_type IS NOT NULL AND v_plan_type <> v_svc_type THEN RAISE EXCEPTION 'PLAN_TYPE_MISMATCH'; END IF;

  -- ── PRIX FAISANT FOI : grille du pays verrouillé > plafond GNF du plan ──────
  SELECT code INTO v_svc_code FROM public.service_types WHERE id = v_svc_type;
  v_grid := public.get_subscription_price_by_country(
              p_user_id, COALESCE(v_svc_code,'service'), v_plan_name, COALESCE(p_cycle,'monthly'));

  IF (v_grid->>'found')::boolean THEN
    -- Le serveur IMPOSE le prix de la grille (le prix client est ignoré).
    v_amount := (v_grid->>'price')::numeric;
    v_metadata := COALESCE(p_metadata,'{}'::jsonb) || jsonb_build_object(
      'priced_by','country_grid',
      'country_code', v_grid->>'country_code',
      'price_currency', v_grid->>'currency_code',
      'commission_rate', v_grid->>'commission_rate');
  ELSE
    -- Repli : ancien comportement (anti-surfacturation par le plafond GNF du plan).
    IF p_amount IS NULL OR p_amount < 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
    v_max_price := COALESCE(v_yearly, v_monthly * 12) + 1;
    IF p_amount > v_max_price THEN RAISE EXCEPTION 'AMOUNT_TOO_HIGH'; END IF;
    v_amount := p_amount;
    v_metadata := COALESCE(p_metadata,'{}'::jsonb) || jsonb_build_object('priced_by','plan_gnf_fallback');
  END IF;

  -- ── DÉBIT + ÉCRITURE (atomique) ──
  v_new_balance := public.wallet_debit_internal(p_user_id, v_amount, p_description, p_idempotency_key);

  IF p_mode = 'switch' THEN
    UPDATE public.service_subscriptions
    SET plan_id = p_plan_id, updated_at = now(), metadata = v_metadata
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
      p_service_id, p_user_id, p_plan_id, COALESCE(v_amount, 0), p_cycle, 'active',
      p_period_start, p_period_start, p_period_end, p_auto_renew, p_payment_method, v_metadata
    )
    RETURNING id INTO v_sub_id;
  END IF;

  RETURN jsonb_build_object(
    'status','created', 'subscription_id', v_sub_id, 'new_balance', v_new_balance,
    'mode', p_mode, 'charged_amount', v_amount, 'priced_by', v_metadata->>'priced_by');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.purchase_service_subscription_atomic(uuid, numeric, text, text, text, uuid, uuid, text, text, timestamptz, timestamptz, boolean, jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.purchase_service_subscription_atomic(uuid, numeric, text, text, text, uuid, uuid, text, text, timestamptz, timestamptz, boolean, jsonb, uuid) TO service_role;

SELECT 'purchase_service_subscription_atomic étendu : prix imposé par la grille du pays verrouillé (repli plafond GNF), même signature (aucune surcharge).' AS status;
