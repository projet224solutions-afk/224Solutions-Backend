-- ════════════════════════════════════════════════════════════════
-- RPC count_nearby_services : 4 COUNT() côté serveur (Haversine)
-- Remplace 4 requêtes client non limitées (milliers de lignes → 1 int).
-- drivers.current_location = POINT texte '(lng,lat)' (vérifié côté client).
-- ════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.count_nearby_services(
  p_lat       float8,
  p_lng       float8,
  p_radius_km float8 DEFAULT 20.0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_boutiques   integer := 0;
  v_taxi        integer := 0;
  v_livraison   integer := 0;
  v_restaurants integer := 0;
BEGIN
  -- Boutiques actives dans le rayon
  SELECT COUNT(*)::integer INTO v_boutiques
  FROM public.vendors v
  WHERE v.is_active = true
    AND v.latitude IS NOT NULL AND v.longitude IS NOT NULL
    AND (6371 * acos(LEAST(1, GREATEST(-1,
      cos(radians(p_lat)) * cos(radians(v.latitude::float8)) *
      cos(radians(v.longitude::float8) - radians(p_lng)) +
      sin(radians(p_lat)) * sin(radians(v.latitude::float8))
    )))) <= p_radius_km;

  -- Taxi-motos en ligne dans le rayon
  SELECT COUNT(*)::integer INTO v_taxi
  FROM public.taxi_drivers td
  WHERE td.is_online = true
    AND td.status IN ('online', 'available')
    AND td.last_lat IS NOT NULL AND td.last_lng IS NOT NULL
    AND (6371 * acos(LEAST(1, GREATEST(-1,
      cos(radians(p_lat)) * cos(radians(td.last_lat::float8)) *
      cos(radians(td.last_lng::float8) - radians(p_lng)) +
      sin(radians(p_lat)) * sin(radians(td.last_lat::float8))
    )))) <= p_radius_km;

  -- Livreurs disponibles (current_location au format POINT texte '(lng,lat)')
  SELECT COUNT(*)::integer INTO v_livraison
  FROM public.drivers d
  WHERE (d.is_online = true OR d.status IN ('active', 'online', 'on_trip'))
    AND d.current_location IS NOT NULL
    AND (6371 * acos(LEAST(1, GREATEST(-1,
      cos(radians(p_lat)) *
      cos(radians(split_part(trim(both '()' from d.current_location::text), ',', 2)::float8)) *
      cos(radians(split_part(trim(both '()' from d.current_location::text), ',', 1)::float8) - radians(p_lng)) +
      sin(radians(p_lat)) *
      sin(radians(split_part(trim(both '()' from d.current_location::text), ',', 2)::float8))
    )))) <= p_radius_km;

  -- Restaurants actifs dans le rayon
  SELECT COUNT(*)::integer INTO v_restaurants
  FROM public.professional_services ps
  JOIN public.service_types st ON st.id = ps.service_type_id
  WHERE ps.status = 'active'
    AND st.code = 'restaurant'
    AND ps.latitude IS NOT NULL AND ps.longitude IS NOT NULL
    AND (6371 * acos(LEAST(1, GREATEST(-1,
      cos(radians(p_lat)) * cos(radians(ps.latitude::float8)) *
      cos(radians(ps.longitude::float8) - radians(p_lng)) +
      sin(radians(p_lat)) * sin(radians(ps.latitude::float8))
    )))) <= p_radius_km;

  RETURN jsonb_build_object(
    'boutiques', v_boutiques, 'taxi', v_taxi,
    'livraison', v_livraison, 'restaurants', v_restaurants
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.count_nearby_services(float8, float8, float8) TO authenticated, anon;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'count_nearby_services') THEN
    RAISE EXCEPTION 'ÉCHEC : RPC count_nearby_services non créée';
  END IF;
  RAISE NOTICE '✅ RPC count_nearby_services créée';
END;
$$;

COMMIT;
