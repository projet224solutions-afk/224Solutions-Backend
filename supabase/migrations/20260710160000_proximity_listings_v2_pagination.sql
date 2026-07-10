-- ============================================================================
-- get_proximity_listings v2 — pagination bornée (p_limit / p_offset)
-- ----------------------------------------------------------------------------
-- Pourquoi : la v1 renvoyait TOUTES les lignes (services pro abonnés + boutiques),
-- exposée au plafond silencieux 1000 de PostgREST. On borne côté serveur avec un
-- LIMIT/OFFSET + un tri STABLE (ordre total garanti par le tie-break sur id) pour
-- que la fenêtre soit déterministe et rejouable.
--
-- NB fonctionnel : la RPC ne connaît PAS la position de l'utilisateur → elle ne
-- peut pas trier par distance. Le tri serveur (note/avis/nom/id) ne sert qu'à
-- borner proprement (les meilleures fiches d'abord). Le tri par distance reste
-- côté client. Une vraie pagination « Voir plus » par offset ne serait donc PAS
-- cohérente avec l'affichage distance ; le client cape à 200 et signale (note)
-- si le plafond est atteint plutôt que de proposer une page 2 trompeuse.
--
-- Compat : signature étendue (uuid[], int, int) avec DEFAULTs → tout appelant
-- existant qui ne passe que p_service_ids continue de fonctionner. On DROP l'ancienne
-- surcharge 1-arg pour éviter toute ambiguïté de résolution PostgREST (PGRST203).
-- Read-only, SECURITY DEFINER, atomique.
-- ============================================================================

-- L'ancienne surcharge 1-arg doit disparaître : deux fonctions callables avec
-- le seul p_service_ids créeraient une ambiguïté. On la remplace par la v2.
DROP FUNCTION IF EXISTS public.get_proximity_listings(uuid[]);

CREATE OR REPLACE FUNCTION public.get_proximity_listings(
  p_service_ids uuid[],
  p_limit       int DEFAULT 200,
  p_offset      int DEFAULT 0
)
RETURNS TABLE (
  id                    uuid,
  source                text,
  business_name         text,
  description           text,
  address               text,
  phone                 text,
  email                 text,
  logo_url              text,
  cover_image_url       text,
  rating                numeric,
  total_reviews         integer,
  effective_city        text,
  neighborhood          text,
  effective_country     text,
  latitude              double precision,
  longitude             double precision,
  service_type_id       uuid,
  service_type_name     text,
  service_type_code     text,
  service_type_category text,
  user_id               uuid
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT q.*
  FROM (
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
      )
  ) q
  -- Tri STABLE (ordre total via tie-break id) : meilleures fiches d'abord, fenêtre déterministe.
  ORDER BY q.rating DESC NULLS LAST,
           q.total_reviews DESC NULLS LAST,
           q.business_name ASC NULLS LAST,
           q.id ASC
  LIMIT  LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$function$;

-- Mêmes grants que la v1 (lecture publique : listings de proximité non sensibles).
GRANT EXECUTE ON FUNCTION public.get_proximity_listings(uuid[], int, int)
  TO anon, authenticated, service_role;

SELECT 'get_proximity_listings v2 (pagination bornée p_limit/p_offset + tri stable) créée.' AS status;
