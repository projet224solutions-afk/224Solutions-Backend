-- ============================================================================
-- RPC ATOMIQUE — localisation effective des services (proximité)
-- ----------------------------------------------------------------------------
-- Problème : une boutique/service a souvent `professional_services.city` VIDE alors
-- que sa ville réelle est sur `vendors.city` (idem GPS, et le pays n'existe QUE sur
-- vendors.country). Le filtre ville excluait donc ces boutiques.
-- Cette RPC résout, en UN SEUL appel (snapshot cohérent, SECURITY DEFINER → fiable
-- même pour les visiteurs anonymes), pour chaque service :
--   • ville effective   = professional_services.city sinon vendors.city
--   • pays effectif      = vendors.country
--   • GPS effectif       = professional_services lat/lng sinon vendors lat/lng
-- Lecture seule, rejouable.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_services_resolved_location(p_service_ids uuid[])
RETURNS TABLE (
  service_id         uuid,
  effective_city     text,
  effective_country  text,
  latitude           double precision,
  longitude          double precision
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT
    ps.id AS service_id,
    COALESCE(
      NULLIF(btrim(COALESCE(ps.city, '')), ''),
      NULLIF(btrim(COALESCE(v.city, '')), '')
    ) AS effective_city,
    NULLIF(btrim(COALESCE(v.country, '')), '') AS effective_country,
    COALESCE(ps.latitude, v.latitude)::double precision  AS latitude,
    COALESCE(ps.longitude, v.longitude)::double precision AS longitude
  FROM public.professional_services ps
  LEFT JOIN public.vendors v ON v.user_id = ps.user_id
  WHERE ps.id = ANY(p_service_ids);
$$;

GRANT EXECUTE ON FUNCTION public.get_services_resolved_location(uuid[])
  TO anon, authenticated, service_role;

SELECT 'get_services_resolved_location créée (ville/pays/GPS effectifs des services, atomique).' AS status;
