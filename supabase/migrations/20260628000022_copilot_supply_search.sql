-- ============================================================================
-- COPILOTE DÉCOUVERTE STOCK — PARTIE 2 : recherche UNIFIÉE du stock découvrable.
-- Sources : products (marketplace) + service_products (prestataires) +
-- pharmacy_medications (pharmacies). LECTURE SEULE.
--
-- 🔒 CONFIDENTIALITÉ ABSOLUE : ne renvoie JAMAIS la quantité — seulement le
--    booléen `available` (stock > 0). Aucun `stock`/`stock_quantity` en sortie.
-- 🔒 GARDE PHARMACIE : exclut les médicaments sur ORDONNANCE (requires_prescription)
--    ET contrôlés/stupéfiants (control_level <> 'none') — jamais annoncés « en stock ».
-- Colonnes vérifiées live : vendors a city ; pharmacy_medications a control_level ;
-- professional_services a city/country/neighborhood.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.copilot_search_supply(
  p_query text,
  p_lat   double precision DEFAULT NULL,
  p_lng   double precision DEFAULT NULL,
  p_limit integer DEFAULT 12
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_q text;
  v_rows jsonb;
BEGIN
  v_q := trim(coalesce(p_query, ''));
  IF length(v_q) < 2 THEN
    RETURN jsonb_build_object('success', false, 'error', 'QUERY_TROP_COURTE');
  END IF;
  v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_'); -- échappe ILIKE

  WITH unified AS (
    -- 1) PRODUITS MARKETPLACE (vendeurs)
    SELECT
      p.id                   AS item_id,
      'product'              AS kind,
      p.name                 AS name,
      p.price                AS price,
      (p.stock_quantity > 0) AS available,           -- ⚠️ booléen, JAMAIS la quantité
      v.business_name        AS seller_name,
      v.country              AS country,
      v.city                 AS city,
      v.address              AS address,
      NULL::text             AS phone,
      NULL::double precision AS latitude,
      NULL::double precision AS longitude,
      true                   AS on_marketplace
    FROM public.products p
    JOIN public.vendors v ON v.id = p.vendor_id
    WHERE p.is_active = true AND p.stock_quantity > 0
      AND p.name ILIKE '%' || v_q || '%'

    UNION ALL
    -- 2) PRODUITS/SERVICES DES PRESTATAIRES (souvent physique)
    SELECT
      sp.id, 'service_product', sp.name, sp.price,
      (sp.stock_quantity > 0),
      ps.business_name, ps.country, ps.city, ps.address, ps.phone,
      ps.latitude, ps.longitude, false
    FROM public.service_products sp
    JOIN public.professional_services ps ON ps.id = sp.professional_service_id
    WHERE sp.is_available = true AND sp.stock_quantity > 0
      AND sp.name ILIKE '%' || v_q || '%'

    UNION ALL
    -- 3) MÉDICAMENTS PHARMACIE — EXCLUT ordonnance + contrôlés (réglementaire)
    SELECT
      m.id, 'medication', m.name, m.price,
      (m.stock > 0),
      ps.business_name, ps.country, ps.city, ps.address, ps.phone,
      ps.latitude, ps.longitude, false
    FROM public.pharmacy_medications m
    JOIN public.professional_services ps ON ps.id = m.pharmacy_id
    WHERE m.is_active = true AND m.stock > 0
      AND m.requires_prescription = false             -- ⚠️ jamais les médicaments sur ordonnance
      AND COALESCE(m.control_level, 'none') = 'none'   -- ⚠️ ni contrôlés/stupéfiants
      AND m.name ILIKE '%' || v_q || '%'
  )
  SELECT COALESCE(jsonb_agg(row_to_json(t) ORDER BY t.dist NULLS LAST), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      item_id, kind, name, price, available,
      seller_name, country, city, address, phone, latitude, longitude, on_marketplace,
      CASE
        WHEN p_lat IS NOT NULL AND latitude IS NOT NULL THEN
          round((6371 * acos(LEAST(1, cos(radians(p_lat)) * cos(radians(latitude)) *
            cos(radians(longitude) - radians(p_lng)) + sin(radians(p_lat)) * sin(radians(latitude)))))::numeric, 1)
        ELSE NULL
      END AS dist
    FROM unified
    ORDER BY dist NULLS LAST              -- les plus proches d'abord (puis le reste)
    LIMIT GREATEST(p_limit, 1)
  ) t;

  RETURN jsonb_build_object('success', true, 'items', v_rows);
EXCEPTION WHEN OTHERS THEN
  -- Robustesse : si une source échoue, ne pas planter (renvoie vide plutôt qu'une erreur 500).
  RETURN jsonb_build_object('success', true, 'items', '[]'::jsonb, 'degraded', true);
END;
$$;

REVOKE ALL ON FUNCTION public.copilot_search_supply(text, double precision, double precision, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.copilot_search_supply(text, double precision, double precision, integer) TO authenticated, service_role;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname='copilot_search_supply')
  THEN RAISE EXCEPTION 'RPC supply absente'; END IF;
  RAISE NOTICE '✅ copilot_search_supply OK';
END; $$;

COMMIT;
