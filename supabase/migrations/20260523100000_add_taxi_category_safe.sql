-- ============================================================
-- MIGRATION SAFE : Ajout taxi_category à taxi_drivers
-- Ne touche pas aux contraintes existantes
-- ============================================================

-- 1. Colonne taxi_category (principal)
ALTER TABLE public.taxi_drivers
  ADD COLUMN IF NOT EXISTS taxi_category VARCHAR(15) DEFAULT 'motorcycle';

-- 2. Colonnes voiture spécifiques
ALTER TABLE public.taxi_drivers
  ADD COLUMN IF NOT EXISTS vehicle_brand VARCHAR(50);

ALTER TABLE public.taxi_drivers
  ADD COLUMN IF NOT EXISTS vehicle_seats INTEGER DEFAULT 4;

-- 3. Backfill : motos existantes → motorcycle, voitures → car
UPDATE public.taxi_drivers
SET taxi_category = 'motorcycle'
WHERE (vehicle_type IN ('moto_economique', 'moto_rapide', 'moto_premium')
       OR vehicle_type ILIKE '%moto%')
  AND taxi_category IS NULL OR taxi_category = 'motorcycle';

UPDATE public.taxi_drivers
SET taxi_category = 'car'
WHERE vehicle_type IN ('berline', 'suv', 'minivan', 'pickup', 'sedan')
  AND taxi_category = 'motorcycle';

-- 4. Index pour les performances
CREATE INDEX IF NOT EXISTS idx_taxi_drivers_category
  ON public.taxi_drivers (taxi_category)
  WHERE is_online = true;

-- 5. Colonne taxi_category dans taxi_rides
ALTER TABLE public.taxi_rides
  ADD COLUMN IF NOT EXISTS taxi_category VARCHAR(15) DEFAULT 'motorcycle';

-- 6. Supprimer l'ancienne version 4-params (crée une ambiguïté RPC)
DROP FUNCTION IF EXISTS public.find_nearby_taxi_drivers(numeric, numeric, numeric, integer);

-- 7. Mettre à jour find_nearby_taxi_drivers pour filtrer par taxi_category
CREATE OR REPLACE FUNCTION public.find_nearby_taxi_drivers(
  p_lat NUMERIC,
  p_lng NUMERIC,
  p_radius_km NUMERIC DEFAULT 20,
  p_limit INTEGER DEFAULT 10,
  p_taxi_category TEXT DEFAULT NULL
)
RETURNS TABLE (
  driver_id UUID,
  user_id UUID,
  distance_km NUMERIC,
  rating NUMERIC,
  vehicle_type TEXT,
  vehicle_plate TEXT,
  taxi_category TEXT
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    td.id AS driver_id,
    td.user_id,
    calculate_distance_km(p_lat, p_lng, td.last_lat, td.last_lng) AS distance_km,
    td.rating,
    td.vehicle_type,
    td.vehicle_plate,
    td.taxi_category
  FROM public.taxi_drivers td
  WHERE
    td.is_online = true
    AND td.status IN ('available', 'active')
    AND td.last_lat IS NOT NULL
    AND td.last_lng IS NOT NULL
    AND calculate_distance_km(p_lat, p_lng, td.last_lat, td.last_lng) <= p_radius_km
    AND (p_taxi_category IS NULL OR td.taxi_category = p_taxi_category)
  ORDER BY distance_km ASC, td.rating DESC
  LIMIT p_limit;
$$;
