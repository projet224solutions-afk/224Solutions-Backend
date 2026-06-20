-- Hard fix: do not return "ghost" drivers left online accidentally
-- 1) Enforce recency via last_seen in nearby search RPC
-- 2) Clean up obviously stale online drivers

CREATE OR REPLACE FUNCTION public.find_nearby_taxi_drivers(
  p_lat numeric,
  p_lng numeric,
  p_radius_km numeric DEFAULT 5.0,
  p_limit integer DEFAULT 10
)
RETURNS TABLE (
  driver_id uuid,
  user_id uuid,
  distance_km numeric,
  rating numeric,
  vehicle_type text,
  vehicle_plate text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    td.id AS driver_id,
    td.user_id,
    (
      6371 * acos(
        cos(radians(p_lat)) * cos(radians(td.last_lat)) *
        cos(radians(td.last_lng) - radians(p_lng)) +
        sin(radians(p_lat)) * sin(radians(td.last_lat))
      )
    )::numeric AS distance_km,
    td.rating,
    td.vehicle_type,
    td.vehicle_plate
  FROM public.taxi_drivers td
  WHERE td.is_online = true
    AND td.status IN ('online', 'available')
    AND td.last_lat IS NOT NULL
    AND td.last_lng IS NOT NULL
    AND td.last_seen IS NOT NULL
    AND td.last_seen > (now() - interval '10 minutes')
    AND (
      6371 * acos(
        cos(radians(p_lat)) * cos(radians(td.last_lat)) *
        cos(radians(td.last_lng) - radians(p_lng)) +
        sin(radians(p_lat)) * sin(radians(td.last_lat))
      )
    ) <= p_radius_km
  ORDER BY distance_km ASC
  LIMIT GREATEST(LEAST(p_limit, 50), 1);
END;
$$;

-- Cleanup: mark stale "online" drivers as offline so they won't appear anywhere
UPDATE public.taxi_drivers
SET
  is_online = false,
  status = 'offline',
  last_lat = NULL,
  last_lng = NULL,
  last_heading = NULL,
  last_speed = NULL,
  last_seen = now()
WHERE is_online = true
  AND (
    last_seen IS NULL
    OR last_seen < (now() - interval '10 minutes')
  );
