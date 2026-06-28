-- ============================================================================
-- PHARMACIE — AMÉLIORATION 2.3 : disponibilité inter-pharmacies (rupture chez X
-- → trouver une pharmacie proche qui a le médicament). Bounding box + Haversine
-- (pas de PostGIS requis). Colonnes professional_services vérifiées :
-- business_name, phone, city, latitude, longitude existent.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.find_medication_nearby(
  p_medication_name text,
  p_lat             double precision,
  p_lng             double precision,
  p_radius_km       double precision DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_rows jsonb;
  v_lat_delta double precision := p_radius_km / 111.0;
  v_lng_delta double precision := p_radius_km / (111.0 * cos(radians(p_lat)));
BEGIN
  IF p_medication_name IS NULL OR length(trim(p_medication_name)) < 2 THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOM_MEDICAMENT_REQUIS');
  END IF;
  IF p_lat IS NULL OR p_lng IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'POSITION_REQUISE');
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(t) ORDER BY (t->>'distance_km')::numeric), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      ps.id AS pharmacy_id, ps.business_name AS pharmacy_name,
      ps.phone AS pharmacy_phone, ps.city AS pharmacy_city,
      ps.latitude, ps.longitude,
      m.name AS medication_name, m.price, m.stock,
      round((6371 * acos(
        LEAST(1, cos(radians(p_lat)) * cos(radians(ps.latitude)) *
                 cos(radians(ps.longitude) - radians(p_lng)) +
                 sin(radians(p_lat)) * sin(radians(ps.latitude)))
      ))::numeric, 1) AS distance_km
    FROM public.pharmacy_medications m
    JOIN public.professional_services ps ON ps.id = m.pharmacy_id
    WHERE m.is_active = true AND m.stock > 0
      AND m.name ILIKE '%' || p_medication_name || '%'
      AND ps.latitude IS NOT NULL AND ps.longitude IS NOT NULL
      AND ps.latitude  BETWEEN p_lat - v_lat_delta AND p_lat + v_lat_delta
      AND ps.longitude BETWEEN p_lng - v_lng_delta AND p_lng + v_lng_delta
  ) t
  WHERE (t->>'distance_km')::numeric <= p_radius_km;

  RETURN jsonb_build_object('success', true, 'pharmacies', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.find_medication_nearby(text, double precision, double precision, double precision) FROM anon;
GRANT  EXECUTE ON FUNCTION public.find_medication_nearby(text, double precision, double precision, double precision) TO authenticated, service_role;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='find_medication_nearby')
  THEN RAISE EXCEPTION 'RPC inter-pharmacies absente'; END IF;
  RAISE NOTICE '✅ Migration inter_pharmacy_availability OK';
END; $$;

COMMIT;
