-- Ajouter colonnes manquantes à taxi_drivers
ALTER TABLE public.taxi_drivers ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'offline';
ALTER TABLE public.taxi_drivers ADD COLUMN IF NOT EXISTS last_lat NUMERIC(10, 7);
ALTER TABLE public.taxi_drivers ADD COLUMN IF NOT EXISTS last_lng NUMERIC(10, 7);
ALTER TABLE public.taxi_drivers ADD COLUMN IF NOT EXISTS last_seen TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE public.taxi_drivers ADD COLUMN IF NOT EXISTS vehicle_type TEXT DEFAULT 'moto';
ALTER TABLE public.taxi_drivers ADD COLUMN IF NOT EXISTS vehicle_plate TEXT;

-- Ajouter colonnes payment à taxi_trips
ALTER TABLE public.taxi_trips ADD COLUMN IF NOT EXISTS payment_status TEXT DEFAULT 'pending';
ALTER TABLE public.taxi_trips ADD COLUMN IF NOT EXISTS payment_method TEXT;

-- Index pour geolocation
CREATE INDEX IF NOT EXISTS idx_drivers_location ON public.taxi_drivers USING GIST(ST_MakePoint(last_lng, last_lat));

-- Fonction find nearby drivers
CREATE OR REPLACE FUNCTION public.find_nearby_taxi_drivers(
  p_lat NUMERIC, p_lng NUMERIC, p_radius_km NUMERIC DEFAULT 5, p_limit INTEGER DEFAULT 10
) RETURNS TABLE (driver_id UUID, user_id UUID, distance_km NUMERIC, is_online BOOLEAN, status TEXT, last_lat NUMERIC, last_lng NUMERIC)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
  SELECT td.id, td.user_id,
    ST_Distance(ST_MakePoint(p_lng, p_lat)::geography, ST_MakePoint(td.last_lng, td.last_lat)::geography) / 1000 AS distance_km,
    td.is_online, td.status, td.last_lat, td.last_lng
  FROM public.taxi_drivers td
  WHERE td.is_online = TRUE AND td.status = 'available'
    AND td.last_lat IS NOT NULL AND td.last_lng IS NOT NULL
    AND ST_DWithin(ST_MakePoint(td.last_lng, td.last_lat)::geography, ST_MakePoint(p_lng, p_lat)::geography, p_radius_km * 1000)
  ORDER BY distance_km ASC LIMIT p_limit;
END; $$;

-- Fonction calcul tarif
CREATE OR REPLACE FUNCTION public.calculate_taxi_fare(
  p_distance_km NUMERIC, p_duration_min INTEGER, p_surge_multiplier NUMERIC DEFAULT 1.0
) RETURNS JSONB LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  base_fare NUMERIC := 1000;
  per_km_rate NUMERIC := 200;
  per_min_rate NUMERIC := 50;
  total NUMERIC;
  platform_fee NUMERIC;
  driver_share NUMERIC;
BEGIN
  total := (base_fare + (p_distance_km * per_km_rate) + (p_duration_min * per_min_rate)) * p_surge_multiplier;
  platform_fee := total * 0.20;
  driver_share := total - platform_fee;
  RETURN jsonb_build_object(
    'total', ROUND(total, 0), 'platform_fee', ROUND(platform_fee, 0), 'driver_share', ROUND(driver_share, 0),
    'base_fare', base_fare, 'distance_fee', ROUND(p_distance_km * per_km_rate, 0),
    'time_fee', ROUND(p_duration_min * per_min_rate, 0), 'surge_multiplier', p_surge_multiplier
  );
END; $$;