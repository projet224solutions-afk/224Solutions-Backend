-- ============================================================================
-- RPC ATOMIQUE — listings de proximité unifiés (services pro + boutiques/vendeurs)
-- ----------------------------------------------------------------------------
-- Problème : une boutique créée comme `vendor` (ex. BMS MULTI-SERVICE à Labé) n'a
-- PAS de fiche `professional_services` → elle n'apparaissait jamais dans les services
-- de proximité (qui ne lisaient que professional_services). Donc impossible à filtrer.
-- Cette RPC renvoie, en UN SEUL appel (snapshot cohérent, SECURITY DEFINER) :
--   1) les services pro fournis (abonnés) + localisation effective ;
--   2) TOUS les vendeurs-boutiques (en ligne/hybride, actifs, avec ville ou GPS)
--      qui ne sont pas déjà représentés par un de ces services (dédoublonnage par user_id).
-- Lecture seule, rejouable.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_proximity_listings(p_service_ids uuid[])
RETURNS TABLE (
  id                     uuid,
  source                 text,
  business_name          text,
  description            text,
  address                text,
  phone                  text,
  email                  text,
  logo_url               text,
  cover_image_url        text,
  rating                 numeric,
  total_reviews          integer,
  effective_city         text,
  neighborhood           text,
  effective_country      text,
  latitude               double precision,
  longitude              double precision,
  service_type_id        uuid,
  service_type_name      text,
  service_type_code      text,
  service_type_category  text,
  user_id                uuid
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  -- 1) Services pro abonnés (ids fournis) + localisation effective (ps sinon vendor)
  SELECT
    ps.id,
    'service'::text AS source,
    ps.business_name,
    ps.description,
    ps.address,
    ps.phone,
    ps.email,
    ps.logo_url,
    ps.cover_image_url,
    ps.rating,
    ps.total_reviews,
    COALESCE(NULLIF(btrim(COALESCE(ps.city, '')), ''), NULLIF(btrim(COALESCE(v.city, '')), '')) AS effective_city,
    ps.neighborhood,
    NULLIF(btrim(COALESCE(v.country, '')), '') AS effective_country,
    COALESCE(ps.latitude, v.latitude)::double precision  AS latitude,
    COALESCE(ps.longitude, v.longitude)::double precision AS longitude,
    ps.service_type_id,
    st.name     AS service_type_name,
    st.code     AS service_type_code,
    st.category AS service_type_category,
    ps.user_id
  FROM public.professional_services ps
  LEFT JOIN public.vendors v       ON v.user_id = ps.user_id
  LEFT JOIN public.service_types st ON st.id = ps.service_type_id
  WHERE ps.id = ANY(p_service_ids) AND ps.status = 'active'

  UNION ALL

  -- 2) Vendeurs-boutiques (en ligne/hybride, actifs, localisés) non déjà représentés ci-dessus
  SELECT
    v.id,
    'vendor'::text AS source,
    v.business_name,
    v.description,
    v.address,
    v.phone,
    v.email,
    v.logo_url,
    v.cover_image_url,
    COALESCE(v.rating, 0)        AS rating,
    COALESCE(v.total_reviews, 0) AS total_reviews,
    NULLIF(btrim(COALESCE(v.city, '')), '') AS effective_city,
    v.neighborhood,
    NULLIF(btrim(COALESCE(v.country, '')), '') AS effective_country,
    v.latitude::double precision  AS latitude,
    v.longitude::double precision AS longitude,
    NULL::uuid     AS service_type_id,
    'Boutique'::text AS service_type_name,
    'boutique'::text AS service_type_code,
    'Commerce'::text AS service_type_category,
    v.user_id
  FROM public.vendors v
  WHERE v.is_active = true
    AND v.business_type IN ('online', 'hybrid')
    AND v.user_id IS NOT NULL
    AND v.user_id NOT IN (
      SELECT ps2.user_id FROM public.professional_services ps2
      WHERE ps2.id = ANY(p_service_ids) AND ps2.user_id IS NOT NULL
    )
    AND (
      NULLIF(btrim(COALESCE(v.city, '')), '') IS NOT NULL
      OR (v.latitude IS NOT NULL AND v.longitude IS NOT NULL)
    );
$$;

GRANT EXECUTE ON FUNCTION public.get_proximity_listings(uuid[])
  TO anon, authenticated, service_role;

SELECT 'get_proximity_listings créée (services pro abonnés + boutiques/vendeurs unifiés, atomique).' AS status;
