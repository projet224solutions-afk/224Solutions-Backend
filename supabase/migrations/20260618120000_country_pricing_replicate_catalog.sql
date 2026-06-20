-- ============================================================================
-- 🌍 RÉPLIQUE DU CATALOGUE GUINÉE VERS TOUS LES PAYS (tous les services).
-- ----------------------------------------------------------------------------
-- La « logique Guinée » = les plans GNF actuels (table `plans` vendeur + `service_plans`
-- des ~13 métiers : agriculture, restaurant, beauté, ecommerce, construction, éducation,
-- immobilier, maison, média, freelance, réparation, pharmacie, clinique…), avec 4 paliers
-- free/basic/pro/premium, commission et limites.
--
-- Ce script :
--   1) Helper `suggest_country_price(gnf, devise)` : convertit le prix GNF en devise locale
--      (taux BCRG via currency_exchange_rates, direct/inverse) + arrondi PROPRE. Sert de
--      POINT DE DÉPART éditable (Modèle B : l'admin ajuste ensuite dans « Prix par pays »).
--   2) RPC `admin_seed_country_prices(pays, overwrite)` : génère/MAJ la grille d'un pays à
--      partir du catalogue GN live (idempotent ; n'écrase PAS les prix édités sauf overwrite).
--   3) Exécution initiale : peuple TOUS les pays actifs.
--
-- Atomique + gardé admin + REVOKE FROM PUBLIC. Free (0) reste 0 partout. Si pas de taux FX
-- pour une devise → la ligne payante est OMISE (l'admin la saisira), free toujours créée.
-- ============================================================================

-- 1) ── Prix local suggéré depuis un prix GNF (arrondi propre) ───────────────
CREATE OR REPLACE FUNCTION public.suggest_country_price(p_gnf numeric, p_to text)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rate numeric; v_local numeric;
BEGIN
  IF p_gnf IS NULL OR p_gnf = 0 THEN RETURN 0; END IF;          -- gratuit = 0 partout
  IF p_to IS NULL OR p_to = 'GNF' THEN RETURN p_gnf; END IF;    -- GN = prix exact

  SELECT CASE WHEN cer.from_currency = 'GNF' THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END
  INTO v_rate
  FROM public.currency_exchange_rates cer
  WHERE ((cer.from_currency = 'GNF' AND cer.to_currency = p_to)
      OR (cer.from_currency = p_to  AND cer.to_currency = 'GNF'))
    AND cer.is_active = true
  ORDER BY cer.retrieved_at DESC
  LIMIT 1;

  IF v_rate IS NULL OR v_rate = 0 THEN RETURN NULL; END IF;     -- pas de taux → admin saisira
  v_local := p_gnf * v_rate;

  -- Arrondi propre selon la devise.
  IF p_to IN ('EUR', 'USD') THEN
    RETURN GREATEST(ROUND(v_local * 2) / 2.0, 0.50);            -- au 0,50 le plus proche, plancher 0,50
  ELSE
    RETURN GREATEST(ROUND(v_local / 100) * 100, 100);           -- à la centaine, plancher 100 (XOF/MAD/…)
  END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.suggest_country_price(numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.suggest_country_price(numeric, text) TO authenticated, service_role;

-- 2a) ── LOGIQUE INTERNE (sans garde admin) — réservée service_role / migration ──
--     Sépare le travail de la garde pour pouvoir l'appeler depuis la migration
--     (SQL Editor = auth.uid() NULL) sans déclencher NOT_ADMIN.
CREATE OR REPLACE FUNCTION public._seed_country_prices_internal(
  p_country_code text, p_overwrite boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cur text; v_inserted int := 0; v_updated int := 0;
BEGIN
  SELECT currency_code INTO v_cur FROM public.countries WHERE country_code = p_country_code AND is_active = true;
  IF v_cur IS NULL THEN RAISE EXCEPTION 'COUNTRY_NOT_FOUND_OR_INACTIVE'; END IF;

  WITH catalog AS (
    -- ~13 services typés (service_plans → service_types.code)
    SELECT st.code AS service_type, sp.name AS plan_code,
           COALESCE(sp.monthly_price_gnf, 0) AS gnf, sp.commission_rate
    FROM public.service_plans sp
    JOIN public.service_types st ON st.id = sp.service_type_id
    WHERE COALESCE(sp.is_active, true) AND st.code IS NOT NULL
    UNION ALL
    -- Vendeur (boutique) → table plans
    SELECT 'vendor' AS service_type, p.name AS plan_code,
           COALESCE(p.monthly_price_gnf, 0) AS gnf, NULL::numeric AS commission_rate
    FROM public.plans p
  ),
  priced AS (
    SELECT c.service_type, c.plan_code, c.commission_rate,
           public.suggest_country_price(c.gnf, v_cur) AS price
    FROM catalog c
  ),
  ins AS (
    INSERT INTO public.subscription_prices
      (country_code, service_type, plan_code, price, currency_code, commission_rate, billing_cycle, is_active)
    SELECT p_country_code, pr.service_type, pr.plan_code, pr.price, v_cur,
           COALESCE(pr.commission_rate, 0), 'monthly', true
    FROM priced pr
    WHERE pr.price IS NOT NULL                                   -- omet les payants sans taux FX
    ON CONFLICT (country_code, service_type, plan_code, billing_cycle) DO UPDATE
      SET price = CASE WHEN p_overwrite THEN EXCLUDED.price ELSE public.subscription_prices.price END,
          commission_rate = CASE WHEN p_overwrite THEN EXCLUDED.commission_rate ELSE public.subscription_prices.commission_rate END,
          currency_code = EXCLUDED.currency_code,
          updated_at = now()
    RETURNING (xmax = 0) AS inserted
  )
  SELECT count(*) FILTER (WHERE inserted), count(*) FILTER (WHERE NOT inserted)
  INTO v_inserted, v_updated FROM ins;

  RETURN jsonb_build_object('success', true, 'country_code', p_country_code,
                            'currency', v_cur, 'inserted', v_inserted, 'updated', v_updated);
END;
$$;
REVOKE EXECUTE ON FUNCTION public._seed_country_prices_internal(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._seed_country_prices_internal(text, boolean) TO service_role;

-- 2b) ── RPC ADMIN (avec garde) — appelée par l'UI / le backend ──────────────
CREATE OR REPLACE FUNCTION public.admin_seed_country_prices(
  p_country_code text, p_overwrite boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'NOT_ADMIN'; END IF;
  RETURN public._seed_country_prices_internal(p_country_code, p_overwrite);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_seed_country_prices(text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_seed_country_prices(text, boolean) TO authenticated, service_role;

-- 3) ── Exécution initiale : peuple TOUS les pays actifs depuis le catalogue GN ──
--     Appelle la fonction INTERNE (pas la garde admin) car le SQL Editor n'a pas d'auth.uid().
DO $$
DECLARE r record; v jsonb;
BEGIN
  FOR r IN SELECT country_code FROM public.countries WHERE is_active = true LOOP
    -- overwrite=false : ne touche pas aux prix déjà posés (ex. seed initial vendor/driver).
    v := public._seed_country_prices_internal(r.country_code, false);
    RAISE NOTICE 'Grille %: %', r.country_code, v;
  END LOOP;
END;
$$;

SELECT 'Catalogue GN répliqué vers tous les pays actifs (FX-suggéré, éditable). RPC admin_seed_country_prices dispo pour (re)générer un pays.' AS status,
       country_code, count(*) AS lignes
FROM public.subscription_prices GROUP BY country_code ORDER BY country_code;
