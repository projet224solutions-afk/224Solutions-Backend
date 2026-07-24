-- ============================================================================
-- Annuaire des grossistes — v2 paramétrable par pays (+ fonction d'état)
-- ============================================================================
-- La signature de retour change (colonne total_count + params pagination) → CREATE OR REPLACE
-- impossible. On DROP explicitement l'ANCIENNE signature (3 args) AVANT de créer la nouvelle,
-- sinon PostgreSQL crée une surcharge et l'appel à 3 args devient ambigu. Les nouveaux params
-- ont des DEFAULT → l'appel à 3 args du frontend actuel continue de fonctionner.
--
-- Motif de sécurité CONSERVÉ : SECURITY DEFINER + SET search_path = public + REVOKE PUBLIC +
-- GRANT anon/authenticated. Jointure certif sur user_id CONSERVÉE (correcte). product_count
-- JAMAIS éliminatoire par défaut (min_product_count = 0 par défaut).
-- ============================================================================

DROP FUNCTION IF EXISTS public.marketplace_certified_suppliers(text, text, text);
DROP FUNCTION IF EXISTS public.marketplace_certified_suppliers(text, text, text, integer, integer);

CREATE FUNCTION public.marketplace_certified_suppliers(
  p_search  text    DEFAULT NULL,
  p_city    text    DEFAULT NULL,
  p_country text    DEFAULT NULL,
  p_limit   integer DEFAULT 50,
  p_offset  integer DEFAULT 0
)
RETURNS TABLE (
  vendor_id     uuid,
  business_name text,
  public_id     text,
  city          text,
  country       text,
  logo_url      text,
  rating        numeric,
  total_reviews integer,
  business_type text,
  description   text,
  sale_type     text,
  product_count bigint,
  total_count   bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code         text;
  v_active       boolean;
  v_enabled      boolean;
  v_require_cert boolean;
  v_sale_types   text[];
  v_min_products integer;
  v_max_results  integer;
  v_limit        integer;
  v_offset       integer;
  v_search       text;
BEGIN
  -- 1. Résoudre p_country → country_code : accepte un CODE ISO-2 ('GN') OU un NOM ('Guinée',
  --    insensible casse/accents). NULL / '' / 'all' → pas de filtre pays.
  IF p_country IS NULL OR btrim(p_country) = '' OR lower(btrim(p_country)) = 'all' THEN
    v_code := NULL;
  ELSE
    SELECT c.country_code INTO v_code
    FROM countries c
    WHERE upper(btrim(p_country)) = c.country_code
       OR extensions.unaccent(lower(btrim(p_country))) = extensions.unaccent(lower(c.country_name))
    LIMIT 1;
    -- Pays hors référentiel → aucun résultat (on ne peut pas filtrer sur un code inexistant).
    IF v_code IS NULL THEN
      RETURN;
    END IF;
  END IF;

  -- 2/4. Config du pays (défauts = comportement historique si pays NULL ou absent de la config).
  IF v_code IS NULL THEN
    v_active := true; v_enabled := true; v_require_cert := true;
    v_sale_types := ARRAY['gros','detail_gros']; v_min_products := 0; v_max_results := 200;
  ELSE
    SELECT co.is_active INTO v_active FROM countries co WHERE co.country_code = v_code;
    v_active := COALESCE(v_active, true);
    SELECT cfg.suppliers_enabled, cfg.require_certification, cfg.allowed_sale_types,
           cfg.min_product_count, cfg.max_results
      INTO v_enabled, v_require_cert, v_sale_types, v_min_products, v_max_results
    FROM country_marketplace_config cfg WHERE cfg.country_code = v_code;
    IF NOT FOUND THEN
      v_enabled := true; v_require_cert := true;
      v_sale_types := ARRAY['gros','detail_gros']; v_min_products := 0; v_max_results := 200;
    END IF;
  END IF;

  -- 3/5. Pays désactivé OU annuaire désactivé → zéro ligne.
  IF v_active = false OR v_enabled = false THEN
    RETURN;
  END IF;

  -- 9/11. Pagination bornée par max_results.
  v_limit  := LEAST(GREATEST(COALESCE(p_limit, 50), 1), COALESCE(v_max_results, 200));
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);

  -- 8. Échapper les jokers ILIKE (sinon une recherche '100%' renvoie toute la table).
  v_search := CASE
    WHEN p_search IS NULL OR btrim(p_search) = '' THEN NULL
    ELSE replace(replace(replace(p_search, '\', '\\'), '%', '\%'), '_', '\_')
  END;

  RETURN QUERY
  WITH base AS (
    SELECT
      v.id, v.business_name, v.public_id::text AS public_id, v.city, v.country, v.logo_url,
      v.rating, v.total_reviews, v.business_type, v.description, v.sale_type,
      (SELECT count(*) FROM products p WHERE p.vendor_id = v.id AND p.is_active) AS pc
    FROM vendors v
    WHERE v.is_active = true
      AND v.sale_type = ANY(v_sale_types)                                  -- 6
      AND (v_code IS NULL OR v.country_code = v_code)                      -- 1 (via index)
      AND (p_city IS NULL OR p_city = '' OR lower(v.city) = lower(p_city))
      AND (v_require_cert = false OR EXISTS (                              -- 5 : conditionnel
            SELECT 1 FROM vendor_certifications c
            WHERE c.vendor_id = v.user_id AND c.status = 'CERTIFIE'))
      AND (                                                                -- 8 : ESCAPE
            v_search IS NULL
        OR  v.business_name              ILIKE '%' || v_search || '%' ESCAPE '\'
        OR  coalesce(v.description, '')   ILIKE '%' || v_search || '%' ESCAPE '\'
        OR  coalesce(v.business_type, '') ILIKE '%' || v_search || '%' ESCAPE '\'
      )
  ),
  filtered AS (
    SELECT * FROM base WHERE pc >= v_min_products                         -- 7 : 0 par défaut = jamais éliminatoire
  )
  SELECT
    f.id, f.business_name, f.public_id, f.city, f.country, f.logo_url,
    f.rating, f.total_reviews, f.business_type, f.description, f.sale_type,
    f.pc AS product_count,
    (SELECT count(*) FROM filtered) AS total_count                        -- 12 : total avant pagination
  FROM filtered f
  ORDER BY
    (CASE WHEN f.pc > 0 THEN 1 ELSE 0 END) DESC,                          -- 10 : catalogue non vide d'abord
    coalesce(f.rating, 0) DESC,
    coalesce(f.total_reviews, 0) DESC,
    f.business_name ASC
  LIMIT v_limit OFFSET v_offset;                                          -- 11
END;
$$;

COMMENT ON FUNCTION public.marketplace_certified_suppliers(text, text, text, integer, integer) IS
  'Annuaire des grossistes, paramétrable par pays via country_marketplace_config (activation, certification requise, types de vente, seuil catalogue, plafond). p_country accepte code ISO-2 ou nom. Rétrocompatible 3 args. total_count = total avant pagination. Lecture publique.';

REVOKE ALL ON FUNCTION public.marketplace_certified_suppliers(text, text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.marketplace_certified_suppliers(text, text, text, integer, integer) TO anon, authenticated;

-- ============================================================================
-- Fonction compagnon : POURQUOI la liste est vide (appelée seulement quand vide côté front).
-- ============================================================================
DROP FUNCTION IF EXISTS public.marketplace_suppliers_country_state(text);
CREATE FUNCTION public.marketplace_suppliers_country_state(p_country text DEFAULT NULL)
RETURNS TABLE (
  country_code          text,
  country_name          text,
  suppliers_enabled     boolean,
  require_certification  boolean,
  total_vendors         bigint,
  certified_vendors     bigint,
  reason                text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code text; v_name text; v_active boolean;
  v_enabled boolean; v_require_cert boolean; v_sale_types text[];
  v_total bigint; v_certified bigint;
BEGIN
  IF p_country IS NULL OR btrim(p_country) = '' OR lower(btrim(p_country)) = 'all' THEN
    -- Pas de pays sélectionné (vue « Mondial ») → état global neutre.
    RETURN QUERY SELECT NULL::text, NULL::text, true, true, 0::bigint, 0::bigint, 'ok'::text;
    RETURN;
  END IF;

  SELECT c.country_code, c.country_name, c.is_active INTO v_code, v_name, v_active
  FROM countries c
  WHERE upper(btrim(p_country)) = c.country_code
     OR extensions.unaccent(lower(btrim(p_country))) = extensions.unaccent(lower(c.country_name))
  LIMIT 1;

  IF v_code IS NULL THEN
    RETURN QUERY SELECT NULL::text, NULL::text, true, true, 0::bigint, 0::bigint, 'country_disabled'::text;
    RETURN;
  END IF;

  SELECT cfg.suppliers_enabled, cfg.require_certification, cfg.allowed_sale_types
    INTO v_enabled, v_require_cert, v_sale_types
  FROM country_marketplace_config cfg WHERE cfg.country_code = v_code;
  IF NOT FOUND THEN
    v_enabled := true; v_require_cert := true; v_sale_types := ARRAY['gros','detail_gros'];
  END IF;

  SELECT count(*),
         count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM vendor_certifications c WHERE c.vendor_id = v.user_id AND c.status = 'CERTIFIE'))
    INTO v_total, v_certified
  FROM vendors v
  WHERE v.is_active = true AND v.country_code = v_code AND v.sale_type = ANY(v_sale_types);

  RETURN QUERY SELECT v_code, v_name, v_enabled, v_require_cert, v_total, v_certified,
    CASE
      WHEN COALESCE(v_active, true) = false THEN 'country_disabled'
      WHEN v_enabled = false            THEN 'feature_disabled'
      WHEN v_total = 0                  THEN 'no_vendors_yet'
      WHEN v_require_cert AND v_certified = 0 THEN 'no_certified_yet'
      ELSE 'ok'
    END::text;
END;
$$;

COMMENT ON FUNCTION public.marketplace_suppliers_country_state(text) IS
  'État de l''annuaire fournisseurs pour un pays (activation, certification requise, nb vendeurs gros, nb certifiés, raison). Sert au frontend à expliquer une liste vide. Lecture publique.';

REVOKE ALL ON FUNCTION public.marketplace_suppliers_country_state(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.marketplace_suppliers_country_state(text) TO anon, authenticated;
