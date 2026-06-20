-- ============================================================================
-- 🌍 PRIX-ZONE APPLIQUÉ À L'ENCAISSEMENT : VENDEUR (boutique) + DRIVER (taxi/livreur).
-- ----------------------------------------------------------------------------
-- Même patron que purchase_service_subscription_atomic : le SERVEUR impose le prix de la
-- ZONE-devise du pays verrouillé (jamais le prix client). Signatures INCHANGÉES → aucune
-- nouvelle surcharge = aucun drift. Repli sur p_amount si pas de grille.
--
-- 1) Ajoute le driver au catalogue de zones (driver_subscription_config : taxi/livreur/both).
-- 2) purchase_vendor_subscription_atomic : grille ('vendor', plans.name).
-- 3) purchase_driver_subscription_atomic : grille ('driver', type ; repli 'both').
-- ============================================================================

-- 1) ── Catalogue de zones ENRICHI avec le driver ────────────────────────────
CREATE OR REPLACE FUNCTION public._seed_zone_prices_internal(
  p_currency text, p_overwrite boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_inserted int := 0; v_updated int := 0;
BEGIN
  IF p_currency IS NULL THEN RAISE EXCEPTION 'CURRENCY_REQUIRED'; END IF;

  WITH catalog AS (
    -- Services typés
    SELECT st.code AS service_type, sp.name AS plan_code,
           COALESCE(sp.monthly_price_gnf, 0) AS gnf, sp.commission_rate
    FROM public.service_plans sp
    JOIN public.service_types st ON st.id = sp.service_type_id
    WHERE COALESCE(sp.is_active, true) AND st.code IS NOT NULL
    UNION ALL
    -- Vendeur (boutique)
    SELECT 'vendor', p.name, COALESCE(p.monthly_price_gnf, 0), NULL::numeric
    FROM public.plans p
    UNION ALL
    -- Driver (taxi / livreur / both) — prix plat depuis driver_subscription_config
    SELECT 'driver', dsc.subscription_type, COALESCE(dsc.price, 0), NULL::numeric
    FROM public.driver_subscription_config dsc
    WHERE COALESCE(dsc.is_active, true)
  ),
  priced AS (
    SELECT c.service_type, c.plan_code, c.commission_rate,
           public.suggest_country_price(c.gnf, p_currency) AS price
    FROM catalog c
  ),
  ins AS (
    INSERT INTO public.subscription_prices
      (country_code, service_type, plan_code, price, currency_code, commission_rate, billing_cycle, is_active)
    SELECT NULL, pr.service_type, pr.plan_code, pr.price, p_currency,
           COALESCE(pr.commission_rate, 0), 'monthly', true
    FROM priced pr
    WHERE pr.price IS NOT NULL
    ON CONFLICT (currency_code, service_type, plan_code, billing_cycle) WHERE country_code IS NULL DO UPDATE
      SET price = CASE WHEN p_overwrite THEN EXCLUDED.price ELSE public.subscription_prices.price END,
          commission_rate = CASE WHEN p_overwrite THEN EXCLUDED.commission_rate ELSE public.subscription_prices.commission_rate END,
          updated_at = now()
    RETURNING (xmax = 0) AS inserted
  )
  SELECT count(*) FILTER (WHERE inserted), count(*) FILTER (WHERE NOT inserted)
  INTO v_inserted, v_updated FROM ins;

  RETURN jsonb_build_object('success', true, 'currency', p_currency, 'inserted', v_inserted, 'updated', v_updated);
END;
$$;
REVOKE EXECUTE ON FUNCTION public._seed_zone_prices_internal(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._seed_zone_prices_internal(text, boolean) TO service_role;

-- Ajoute les lignes driver à toutes les zones existantes (sans écraser les prix édités).
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT DISTINCT currency_code FROM public.countries WHERE is_active = true LOOP
    PERFORM public._seed_zone_prices_internal(r.currency_code, false);
  END LOOP;
END; $$;

-- 2) ── VENDEUR (boutique) : prix imposé par la zone ─────────────────────────
CREATE OR REPLACE FUNCTION public.purchase_vendor_subscription_atomic(
  p_user_id uuid, p_amount numeric, p_idempotency_key text, p_description text,
  p_mode text, p_plan_id uuid, p_cycle text, p_payment_method text,
  p_period_start timestamptz, p_period_end timestamptz, p_auto_renew boolean,
  p_metadata jsonb, p_current_sub_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_new_balance numeric; v_sub_id uuid;
  v_plan_name text; v_grid jsonb; v_amount numeric; v_metadata jsonb;
BEGIN
  SELECT name INTO v_plan_name FROM public.plans WHERE id = p_plan_id;

  -- Prix faisant foi : grille de zone (devise du pays verrouillé) > prix client.
  v_grid := public.get_subscription_price_by_country(p_user_id, 'vendor', v_plan_name, COALESCE(p_cycle,'monthly'));
  IF (v_grid->>'found')::boolean THEN
    v_amount := (v_grid->>'price')::numeric;
    v_metadata := COALESCE(p_metadata,'{}'::jsonb) || jsonb_build_object(
      'priced_by','zone_grid', 'price_currency', v_grid->>'currency_code',
      'country_code', v_grid->>'country_code');
  ELSE
    IF p_amount IS NULL OR p_amount < 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
    v_amount := p_amount;
    v_metadata := COALESCE(p_metadata,'{}'::jsonb) || jsonb_build_object('priced_by','client_amount_fallback');
  END IF;

  v_new_balance := public.wallet_debit_internal(p_user_id, v_amount, p_description, p_idempotency_key);

  IF p_mode = 'switch' THEN
    UPDATE public.subscriptions
    SET plan_id = p_plan_id, updated_at = now(), metadata = v_metadata
    WHERE id = p_current_sub_id
    RETURNING id INTO v_sub_id;
    IF v_sub_id IS NULL THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_FOUND'; END IF;
  ELSE
    UPDATE public.subscriptions
    SET status = 'expired', updated_at = now()
    WHERE user_id = p_user_id AND status IN ('active', 'trialing');

    INSERT INTO public.subscriptions (
      user_id, plan_id, price_paid_gnf, billing_cycle, status,
      started_at, current_period_start, current_period_end, auto_renew, payment_method, metadata
    ) VALUES (
      p_user_id, p_plan_id, COALESCE(v_amount, 0), p_cycle, 'active',
      p_period_start, p_period_start, p_period_end, p_auto_renew, p_payment_method, v_metadata
    )
    RETURNING id INTO v_sub_id;
  END IF;

  RETURN jsonb_build_object('status','created', 'subscription_id', v_sub_id, 'new_balance', v_new_balance,
                            'mode', p_mode, 'charged_amount', v_amount, 'priced_by', v_metadata->>'priced_by');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.purchase_vendor_subscription_atomic(uuid, numeric, text, text, text, uuid, text, text, timestamptz, timestamptz, boolean, jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.purchase_vendor_subscription_atomic(uuid, numeric, text, text, text, uuid, text, text, timestamptz, timestamptz, boolean, jsonb, uuid) TO service_role;

-- 3) ── DRIVER (taxi / livreur) : prix imposé par la zone ────────────────────
CREATE OR REPLACE FUNCTION public.purchase_driver_subscription_atomic(
  p_user_id uuid, p_amount numeric, p_idempotency_key text, p_description text,
  p_driver_type text, p_cycle text, p_payment_method text,
  p_start_date timestamptz, p_end_date timestamptz, p_transaction_id text, p_metadata jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_new_balance numeric; v_sub_id uuid; v_grid jsonb; v_amount numeric; v_metadata jsonb;
BEGIN
  -- Grille de zone : type exact (taxi/livreur), repli sur 'both'.
  v_grid := public.get_subscription_price_by_country(p_user_id, 'driver', p_driver_type, COALESCE(p_cycle,'monthly'));
  IF NOT COALESCE((v_grid->>'found')::boolean, false) THEN
    v_grid := public.get_subscription_price_by_country(p_user_id, 'driver', 'both', COALESCE(p_cycle,'monthly'));
  END IF;

  IF COALESCE((v_grid->>'found')::boolean, false) THEN
    v_amount := (v_grid->>'price')::numeric;
    v_metadata := COALESCE(p_metadata,'{}'::jsonb) || jsonb_build_object(
      'priced_by','zone_grid', 'price_currency', v_grid->>'currency_code', 'country_code', v_grid->>'country_code');
  ELSE
    IF p_amount IS NULL OR p_amount < 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
    v_amount := p_amount;
    v_metadata := COALESCE(p_metadata,'{}'::jsonb) || jsonb_build_object('priced_by','client_amount_fallback');
  END IF;

  v_new_balance := public.wallet_debit_internal(p_user_id, v_amount, p_description, p_idempotency_key);

  UPDATE public.driver_subscriptions
  SET status = 'expired', updated_at = now()
  WHERE user_id = p_user_id AND status = 'active';

  INSERT INTO public.driver_subscriptions (
    user_id, type, price, status, start_date, end_date, payment_method, transaction_id, billing_cycle, metadata
  ) VALUES (
    p_user_id, p_driver_type, COALESCE(v_amount, 0), 'active', p_start_date, p_end_date,
    p_payment_method, p_transaction_id, p_cycle, v_metadata
  )
  RETURNING id INTO v_sub_id;

  BEGIN
    INSERT INTO public.driver_subscription_revenues (subscription_id, user_id, amount, payment_method, transaction_id)
    VALUES (v_sub_id, p_user_id, COALESCE(v_amount, 0), p_payment_method, p_transaction_id);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object('status','created', 'subscription_id', v_sub_id, 'new_balance', v_new_balance,
                            'mode','new', 'charged_amount', v_amount, 'priced_by', v_metadata->>'priced_by');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.purchase_driver_subscription_atomic(uuid, numeric, text, text, text, text, text, timestamptz, timestamptz, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.purchase_driver_subscription_atomic(uuid, numeric, text, text, text, text, text, timestamptz, timestamptz, text, jsonb) TO service_role;

SELECT 'Vendeur + Driver étendus au prix-zone (signatures identiques). Driver ajouté au catalogue de zones.' AS status;
