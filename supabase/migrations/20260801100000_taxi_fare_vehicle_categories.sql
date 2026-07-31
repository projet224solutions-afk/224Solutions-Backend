-- ============================================================================
-- TAXI-MOTO : tarification par CATÉGORIE de moto (100 % SERVEUR, réglable PDG)
-- ----------------------------------------------------------------------------
-- Débloque le vrai multi-offres (Moto éco / rapide / premium) SANS JAMAIS fabriquer
-- de prix côté client : le client CHOISIT une catégorie, le SERVEUR applique un
-- multiplicateur (grille pdg_settings) au tarif haversine existant.
--
-- Basé sur les fonctions RÉELLEMENT déployées (vérifiées via l'API Management) :
--   calculate_taxi_fare : base 5000 + 1500/km + 200/min, commission 15 %, clés total_fare/…
--   create_taxi_ride    : prix serveur haversine, accepte déjà p_vehicle_type (non utilisé jusqu'ici).
-- Rétro-compatible : catégorie inconnue / 'moto' / appel 3 args → multiplicateur 1.0 (= comportement actuel).
-- ============================================================================

-- 1) Grille de multiplicateurs par catégorie (réglable PDG). Catégorie absente → 1.0.
INSERT INTO public.pdg_settings (setting_key, setting_value, description)
SELECT 'taxi_vehicle_multipliers',
  '{"moto_economique": 1.0, "moto_rapide": 1.25, "moto_premium": 1.6}'::jsonb,
  'Multiplicateur de tarif taxi par catégorie de moto (appliqué au prix serveur).'
WHERE NOT EXISTS (SELECT 1 FROM public.pdg_settings WHERE setting_key = 'taxi_vehicle_multipliers');

-- 2) calculate_taxi_fare étendu avec la catégorie. On DROP l'ancienne 3-args puis on recrée en 4-args
--    (défaut p_vehicle_type) : un appel 3 args résout désormais vers cette version (eco ×1.0).
--    SECURITY DEFINER : lit la grille pdg_settings quel que soit l'appelant (RLS PDG), sans exposer d'écriture.
DROP FUNCTION IF EXISTS public.calculate_taxi_fare(numeric, integer, numeric);

CREATE OR REPLACE FUNCTION public.calculate_taxi_fare(
  p_distance_km numeric,
  p_duration_min integer,
  p_surge_multiplier numeric DEFAULT 1.0,
  p_vehicle_type text DEFAULT 'moto_economique'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  base_fare NUMERIC := 5000;
  rate_per_km NUMERIC := 1500;
  rate_per_min NUMERIC := 200;
  platform_commission NUMERIC := 0.15;
  v_cat  text := COALESCE(NULLIF(p_vehicle_type, ''), 'moto_economique');
  v_mult NUMERIC;
  fare_before_surge NUMERIC;
  total_fare NUMERIC;
  driver_share NUMERIC;
  platform_fee NUMERIC;
BEGIN
  SELECT (setting_value ->> v_cat)::numeric INTO v_mult
  FROM public.pdg_settings WHERE setting_key = 'taxi_vehicle_multipliers' LIMIT 1;
  v_mult := COALESCE(v_mult, 1.0);
  IF v_mult <= 0 THEN v_mult := 1.0; END IF;  -- garde-fou : jamais un prix nul/négatif

  fare_before_surge := (base_fare + (p_distance_km * rate_per_km) + (p_duration_min * rate_per_min)) * v_mult;
  total_fare   := ROUND(fare_before_surge * p_surge_multiplier);
  platform_fee := ROUND(total_fare * platform_commission);
  driver_share := total_fare - platform_fee;

  RETURN jsonb_build_object(
    'total_fare', total_fare,
    'driver_share', driver_share,
    'platform_fee', platform_fee,
    'base_fare', ROUND(base_fare * v_mult),
    'distance_charge', ROUND(p_distance_km * rate_per_km * v_mult),
    'duration_charge', ROUND(p_duration_min * rate_per_min * v_mult),
    'surge_multiplier', p_surge_multiplier,
    'vehicle_type', v_cat,
    'vehicle_multiplier', v_mult
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.calculate_taxi_fare(numeric, integer, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.calculate_taxi_fare(numeric, integer, numeric, text) TO authenticated, service_role;

-- 3) create_taxi_ride : passe la catégorie au calcul → le prix FACTURÉ reflète la catégorie choisie.
--    Corps identique au déployé, SEULE la ligne calculate_taxi_fare change (ajout de p_vehicle_type).
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

  IF EXISTS (SELECT 1 FROM public.taxi_trips
             WHERE customer_id = p_rider_id
               AND status IN ('requested', 'accepted', 'arriving', 'in_progress')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'RIDE_ALREADY_ACTIVE');
  END IF;

  v_hav_km := 2 * 6371 * asin(sqrt(
    power(sin(radians(p_dropoff_lat - p_pickup_lat) / 2), 2) +
    cos(radians(p_pickup_lat)) * cos(radians(p_dropoff_lat)) *
    power(sin(radians(p_dropoff_lng - p_pickup_lng) / 2), 2)));

  v_distance_km := CASE
    WHEN p_client_distance_km IS NOT NULL
         AND p_client_distance_km >= v_hav_km * 0.9
         AND p_client_distance_km <= v_hav_km * 3
      THEN p_client_distance_km
    ELSE GREATEST(v_hav_km, 0.5) END;

  IF v_distance_km > 200 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_DISTANCE');
  END IF;

  v_duration_min := GREATEST(ROUND(v_distance_km * 3), 2);
  IF p_client_duration_min IS NOT NULL AND p_client_duration_min BETWEEN v_duration_min * 0.5 AND v_duration_min * 3 THEN
    v_duration_min := p_client_duration_min;
  END IF;

  -- Prix via la SEULE source de vérité — avec la CATÉGORIE choisie (multiplicateur serveur).
  v_fare := public.calculate_taxi_fare(v_distance_km, v_duration_min, 1.0, p_vehicle_type);
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

SELECT 'Tarif taxi par catégorie : grille pdg_settings + calculate_taxi_fare(4 args) + create_taxi_ride passe la catégorie.' AS status;
