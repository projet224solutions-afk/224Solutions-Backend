-- ============================================================================
-- 🌍 TARIFICATION PAR ZONE-DEVISE (zone euro = MÊME prix garanti).
-- ----------------------------------------------------------------------------
-- Avant : 1 prix par PAYS (deux pays euro pouvaient diverger). Après : le prix est
-- porté par la DEVISE (country_code IS NULL = prix de zone), + override par pays optionnel.
-- Résolution : pays → devise → (override pays s'il existe, sinon prix de zone).
-- → Tous les pays d'une même devise (EUR, XOF, XAF…) partagent automatiquement le même prix.
--
-- Idempotent. Atomique + gardé admin + REVOKE FROM PUBLIC.
-- ============================================================================

-- 1) ── Schéma : country_code devient OPTIONNEL (NULL = prix de zone) ─────────
ALTER TABLE public.subscription_prices ALTER COLUMN country_code DROP NOT NULL;

-- Unicité d'un prix de ZONE (par devise) quand country_code IS NULL.
CREATE UNIQUE INDEX IF NOT EXISTS uq_subprice_zone
  ON public.subscription_prices (currency_code, service_type, plan_code, billing_cycle)
  WHERE country_code IS NULL;
CREATE INDEX IF NOT EXISTS idx_subprice_currency ON public.subscription_prices (currency_code, service_type, is_active);

-- 2) ── Re-seed : on repart des prix de ZONE (purge des anciennes lignes par pays) ──
-- (Données de config uniquement ; aucune transaction n'en dépend.)
DELETE FROM public.subscription_prices;

-- 3) ── Seed interne d'une ZONE-devise depuis le catalogue GN (FX-suggéré) ────
CREATE OR REPLACE FUNCTION public._seed_zone_prices_internal(
  p_currency text, p_overwrite boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_inserted int := 0; v_updated int := 0;
BEGIN
  IF p_currency IS NULL THEN RAISE EXCEPTION 'CURRENCY_REQUIRED'; END IF;

  WITH catalog AS (
    SELECT st.code AS service_type, sp.name AS plan_code,
           COALESCE(sp.monthly_price_gnf, 0) AS gnf, sp.commission_rate
    FROM public.service_plans sp
    JOIN public.service_types st ON st.id = sp.service_type_id
    WHERE COALESCE(sp.is_active, true) AND st.code IS NOT NULL
    UNION ALL
    SELECT 'vendor', p.name, COALESCE(p.monthly_price_gnf, 0), NULL::numeric
    FROM public.plans p
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

-- 4) ── Exécution : une grille par DEVISE distincte des pays actifs ───────────
DO $$
DECLARE r record; v jsonb;
BEGIN
  FOR r IN SELECT DISTINCT currency_code FROM public.countries WHERE is_active = true LOOP
    v := public._seed_zone_prices_internal(r.currency_code, true);
    RAISE NOTICE 'Zone %: %', r.currency_code, v;
  END LOOP;
END;
$$;

-- 5) ── Résolveur : pays → devise → (override pays, sinon prix de zone) ───────
CREATE OR REPLACE FUNCTION public.get_subscription_price_by_country(
  p_user_id uuid, p_service_type text, p_plan text, p_cycle text DEFAULT 'monthly'
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cc text; v_cur text; v_flag text; v_sym text; v_row public.subscription_prices%ROWTYPE;
BEGIN
  SELECT p.country_code, c.currency_code, c.flag_emoji, c.currency_symbol
  INTO v_cc, v_cur, v_flag, v_sym
  FROM public.profiles p LEFT JOIN public.countries c ON c.country_code = p.country_code
  WHERE p.id = p_user_id;

  IF v_cc IS NULL OR v_cur IS NULL THEN RETURN jsonb_build_object('found', false, 'reason', 'NO_COUNTRY'); END IF;

  -- a) Override spécifique au pays (rare), sinon b) prix de zone (devise).
  SELECT * INTO v_row FROM public.subscription_prices
  WHERE service_type = p_service_type AND plan_code = p_plan
    AND billing_cycle = COALESCE(p_cycle,'monthly') AND is_active = true
    AND (country_code = v_cc OR (country_code IS NULL AND currency_code = v_cur))
  ORDER BY (country_code = v_cc) DESC   -- override d'abord
  LIMIT 1;

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('found', false, 'reason', 'NO_GRID_PRICE', 'country_code', v_cc, 'currency_code', v_cur);
  END IF;

  RETURN jsonb_build_object(
    'found', true, 'country_code', v_cc, 'currency_code', v_row.currency_code, 'currency_symbol', v_sym,
    'service_type', p_service_type, 'plan_code', p_plan, 'price', v_row.price,
    'commission_rate', v_row.commission_rate, 'billing_cycle', v_row.billing_cycle,
    'flag_emoji', v_flag, 'scope', CASE WHEN v_row.country_code IS NULL THEN 'zone' ELSE 'country_override' END
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_subscription_price_by_country(uuid, text, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_subscription_price_by_country(uuid, text, text, text) TO authenticated, service_role;

-- 6) ── Admin : poser un prix = prix de ZONE (devise du pays) → MÊME prix partout ──
CREATE OR REPLACE FUNCTION public.admin_set_subscription_price(
  p_country_code text, p_service_type text, p_plan_code text, p_price numeric,
  p_commission_rate numeric DEFAULT NULL, p_cycle text DEFAULT 'monthly', p_is_active boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cur text;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'NOT_ADMIN'; END IF;
  IF p_price IS NULL OR p_price < 0 THEN RAISE EXCEPTION 'INVALID_PRICE'; END IF;

  SELECT currency_code INTO v_cur FROM public.countries WHERE country_code = p_country_code AND is_active = true;
  IF v_cur IS NULL THEN RAISE EXCEPTION 'COUNTRY_NOT_FOUND_OR_INACTIVE'; END IF;

  -- Prix de ZONE (country_code NULL) : s'applique à TOUS les pays de cette devise.
  INSERT INTO public.subscription_prices (country_code, service_type, plan_code, price, currency_code, commission_rate, billing_cycle, is_active)
  VALUES (NULL, p_service_type, p_plan_code, p_price, v_cur, COALESCE(p_commission_rate,0), COALESCE(p_cycle,'monthly'), COALESCE(p_is_active,true))
  ON CONFLICT (currency_code, service_type, plan_code, billing_cycle) WHERE country_code IS NULL DO UPDATE
    SET price = EXCLUDED.price,
        commission_rate = COALESCE(p_commission_rate, public.subscription_prices.commission_rate),
        is_active = EXCLUDED.is_active, updated_at = now();

  RETURN jsonb_build_object('success', true, 'currency_code', v_cur, 'price', p_price, 'scope', 'zone');
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_set_subscription_price(text, text, text, numeric, numeric, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_set_subscription_price(text, text, text, numeric, numeric, text, boolean) TO authenticated, service_role;

-- 7) ── Admin : (re)générer la grille = seed de la ZONE-devise du pays ────────
CREATE OR REPLACE FUNCTION public.admin_seed_country_prices(
  p_country_code text, p_overwrite boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cur text;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'NOT_ADMIN'; END IF;
  SELECT currency_code INTO v_cur FROM public.countries WHERE country_code = p_country_code AND is_active = true;
  IF v_cur IS NULL THEN RAISE EXCEPTION 'COUNTRY_NOT_FOUND_OR_INACTIVE'; END IF;
  RETURN public._seed_zone_prices_internal(v_cur, p_overwrite);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_seed_country_prices(text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_seed_country_prices(text, boolean) TO authenticated, service_role;

-- 8) ── RLS : un client lit les prix de SA devise (zone) + override de son pays ──
DROP POLICY IF EXISTS subprices_read_own_country ON public.subscription_prices;
CREATE POLICY subprices_read_own_country ON public.subscription_prices FOR SELECT TO authenticated
  USING (
    public.is_admin_or_pdg()
    OR currency_code = (
      SELECT c.currency_code FROM public.profiles p
      JOIN public.countries c ON c.country_code = p.country_code
      WHERE p.id = auth.uid()
    )
  );

SELECT currency_code, count(*) AS lignes
FROM public.subscription_prices GROUP BY currency_code ORDER BY currency_code;
