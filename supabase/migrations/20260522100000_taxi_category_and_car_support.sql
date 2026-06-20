-- ============================================================
-- MIGRATION : Module Taxi Général (Voiture + Moto)
-- Ajoute taxi_category à taxi_drivers et met à jour les fonctions RPC
-- ============================================================

-- 1. Ajouter la colonne taxi_category
ALTER TABLE public.taxi_drivers
  ADD COLUMN IF NOT EXISTS taxi_category VARCHAR(15) DEFAULT 'motorcycle'
  CHECK (taxi_category IN ('car', 'motorcycle'));

-- 2. Mettre à jour la contrainte vehicle_type pour accepter les types voiture
-- (drop la contrainte existante et en créer une nouvelle)
ALTER TABLE public.taxi_drivers
  DROP CONSTRAINT IF EXISTS taxi_drivers_vehicle_type_check;

ALTER TABLE public.taxi_drivers
  ADD CONSTRAINT taxi_drivers_vehicle_type_check
  CHECK (vehicle_type IN (
    -- Types moto (existants)
    'moto_economique', 'moto_rapide', 'moto_premium',
    -- Types voiture (nouveaux)
    'berline', 'suv', 'minivan', 'pickup', 'sedan'
  ));

-- 3. Ajouter colonnes voiture spécifiques
ALTER TABLE public.taxi_drivers
  ADD COLUMN IF NOT EXISTS vehicle_brand VARCHAR(50),
  ADD COLUMN IF NOT EXISTS vehicle_seats INTEGER DEFAULT 4,
  ADD COLUMN IF NOT EXISTS has_client_helmet BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS vehicle JSONB DEFAULT '{}';

-- 4. Mettre à jour find_nearby_taxi_drivers pour filtrer par taxi_category
DROP FUNCTION IF EXISTS public.find_nearby_taxi_drivers(NUMERIC, NUMERIC, NUMERIC, INTEGER);
DROP FUNCTION IF EXISTS public.find_nearby_taxi_drivers(NUMERIC, NUMERIC, NUMERIC, INTEGER, TEXT);

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
    AND td.status = 'active'
    AND td.last_lat IS NOT NULL
    AND td.last_lng IS NOT NULL
    AND calculate_distance_km(p_lat, p_lng, td.last_lat, td.last_lng) <= p_radius_km
    AND (p_taxi_category IS NULL OR td.taxi_category = p_taxi_category)
  ORDER BY distance_km ASC, td.rating DESC
  LIMIT p_limit;
$$;

-- 5. Index pour améliorer les performances sur taxi_category
CREATE INDEX IF NOT EXISTS idx_taxi_drivers_category
  ON public.taxi_drivers (taxi_category)
  WHERE is_online = true;

-- 6. Mettre à jour les anciens chauffeurs : si vehicle_type commence par 'moto_', taxi_category = 'motorcycle'
UPDATE public.taxi_drivers
SET taxi_category = 'motorcycle'
WHERE vehicle_type IN ('moto_economique', 'moto_rapide', 'moto_premium')
  AND taxi_category IS NULL;

-- 7. Ajouter taxi_category aux rides pour tracking
ALTER TABLE public.taxi_rides
  ADD COLUMN IF NOT EXISTS taxi_category VARCHAR(15) DEFAULT 'motorcycle';

-- 8. Vue utilitaire pour les stats PDG
CREATE OR REPLACE VIEW public.taxi_drivers_by_category AS
SELECT
  taxi_category,
  COUNT(*) AS total_drivers,
  COUNT(*) FILTER (WHERE is_online = true) AS online_drivers,
  AVG(rating)::NUMERIC(3,2) AS avg_rating
FROM public.taxi_drivers
GROUP BY taxi_category;
