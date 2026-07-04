-- ============================================================================
-- 🛡️ TAXI-MOTO : création de course À PRIX SERVEUR (fin du prix falsifiable)
-- ----------------------------------------------------------------------------
-- AVANT : TaxiMotoService.createRide faisait un INSERT client-side dans taxi_trips avec
-- price_total = estimatedPrice (VENU DU NAVIGATEUR) + driver_share/platform_fee calculés
-- côté client → un utilisateur pouvait créer une course à 500 GNF au lieu de 15 000.
-- APRÈS : cette RPC recalcule distance (haversine, plancher de sécurité) + prix
-- (calculate_taxi_fare, seule source de vérité). AUCUN prix client accepté.
--
-- customer_id = auth.uid transmis par la route backend (jamais du body).
-- Migration livrée — NON exécutée.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.create_taxi_ride(
  p_rider_id           uuid,
  p_pickup_lat         numeric,
  p_pickup_lng         numeric,
  p_dropoff_lat        numeric,
  p_dropoff_lng        numeric,
  p_pickup_address     text,
  p_dropoff_address    text,
  p_vehicle_type       text DEFAULT 'moto',
  p_payment_method     text DEFAULT 'cash',
  p_client_distance_km numeric DEFAULT NULL,
  p_client_duration_min int DEFAULT NULL,
  p_metadata           jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_hav_km      numeric;
  v_distance_km numeric;
  v_duration_min int;
  v_fare        jsonb;
  v_price       numeric;
  v_driver      numeric;
  v_platform    numeric;
  v_ride_code   text;
  v_ride        RECORD;
BEGIN
  IF p_rider_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'RIDER_REQUIRED');
  END IF;
  IF p_pickup_lat IS NULL OR p_pickup_lng IS NULL OR p_dropoff_lat IS NULL OR p_dropoff_lng IS NULL
     OR (p_pickup_lat = p_dropoff_lat AND p_pickup_lng = p_dropoff_lng) THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_COORDINATES');
  END IF;

  -- Anti-doublon : une seule course active par rider.
  IF EXISTS (SELECT 1 FROM public.taxi_trips
             WHERE customer_id = p_rider_id
               AND status IN ('requested', 'accepted', 'arriving', 'in_progress')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'RIDE_ALREADY_ACTIVE');
  END IF;

  -- Distance recalculée serveur (haversine, km) — ne JAMAIS faire confiance au client.
  v_hav_km := 2 * 6371 * asin(sqrt(
    power(sin(radians(p_dropoff_lat - p_pickup_lat) / 2), 2) +
    cos(radians(p_pickup_lat)) * cos(radians(p_dropoff_lat)) *
    power(sin(radians(p_dropoff_lng - p_pickup_lng) / 2), 2)));

  -- La distance routière Google (client) est légitime et > vol d'oiseau ; on l'accepte si
  -- plausible (0,9× à 3× la haversine), sinon plancher haversine (refuse un client anormalement bas).
  v_distance_km := CASE
    WHEN p_client_distance_km IS NOT NULL
         AND p_client_distance_km >= v_hav_km * 0.9
         AND p_client_distance_km <= v_hav_km * 3
      THEN p_client_distance_km
    ELSE GREATEST(v_hav_km, 0.5) END;

  -- Borne haute de sécurité (course moto absurde).
  IF v_distance_km > 200 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_DISTANCE');
  END IF;

  -- Durée recalculée serveur (≈ 3 min/km), ignore une durée client non plausible.
  v_duration_min := GREATEST(ROUND(v_distance_km * 3), 2);
  IF p_client_duration_min IS NOT NULL AND p_client_duration_min BETWEEN v_duration_min * 0.5 AND v_duration_min * 3 THEN
    v_duration_min := p_client_duration_min;
  END IF;

  -- Prix via la SEULE source de vérité.
  v_fare := public.calculate_taxi_fare(v_distance_km, v_duration_min, 1.0);
  v_price    := COALESCE((v_fare->>'total_fare')::numeric, (v_fare->>'price_total')::numeric);
  v_driver   := (v_fare->>'driver_share')::numeric;
  v_platform := (v_fare->>'platform_fee')::numeric;
  IF v_price IS NULL OR v_price <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'FARE_CALCULATION_FAILED');
  END IF;

  v_ride_code := public.generate_taxi_code('TMR');

  INSERT INTO public.taxi_trips (
    ride_code, customer_id, pickup_lat, pickup_lng, pickup_address,
    dropoff_lat, dropoff_lng, dropoff_address, distance_km, duration_min,
    price_total, driver_share, platform_fee, status, payment_status, payment_method, metadata)
  VALUES (
    v_ride_code, p_rider_id, p_pickup_lat, p_pickup_lng, p_pickup_address,
    p_dropoff_lat, p_dropoff_lng, p_dropoff_address, v_distance_km, v_duration_min,
    v_price, v_driver, v_platform, 'requested', 'pending', COALESCE(p_payment_method, 'cash'),
    COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object('vehicle_type', p_vehicle_type, 'server_priced', true))
  RETURNING * INTO v_ride;

  RETURN jsonb_build_object('success', true,
    'ride', to_jsonb(v_ride),
    'price_total', v_price, 'distance_km', v_distance_km, 'duration_min', v_duration_min);
END;
$$;

REVOKE ALL ON FUNCTION public.create_taxi_ride(uuid, numeric, numeric, numeric, numeric, text, text, text, text, numeric, int, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_taxi_ride(uuid, numeric, numeric, numeric, numeric, text, text, text, text, numeric, int, jsonb) TO service_role;

SELECT '✅ create_taxi_ride : prix serveur (calculate_taxi_fare), distance haversine, anti-doublon, anti-prix-client' AS status;
