-- Fix: Allow detection of drivers with status 'online' OR 'available'
CREATE OR REPLACE FUNCTION public.find_nearby_taxi_drivers(
  p_lat numeric,
  p_lng numeric,
  p_radius_km numeric DEFAULT 10
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  full_name text,
  phone text,
  avatar_url text,
  vehicle_type text,
  vehicle_plate text,
  rating numeric,
  total_trips integer,
  distance_km numeric,
  last_lat numeric,
  last_lng numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    td.id,
    td.user_id,
    p.full_name,
    p.phone,
    p.avatar_url,
    td.vehicle_type,
    td.vehicle_plate,
    td.rating,
    td.total_trips,
    (
      6371 * acos(
        cos(radians(p_lat)) * cos(radians(td.last_lat)) *
        cos(radians(td.last_lng) - radians(p_lng)) +
        sin(radians(p_lat)) * sin(radians(td.last_lat))
      )
    )::numeric AS distance_km,
    td.last_lat,
    td.last_lng
  FROM taxi_drivers td
  LEFT JOIN profiles p ON p.id = td.user_id
  WHERE td.is_online = true
    AND td.status IN ('online', 'available')  -- Fixed: Accept both statuses
    AND td.last_lat IS NOT NULL
    AND td.last_lng IS NOT NULL
    AND (
      6371 * acos(
        cos(radians(p_lat)) * cos(radians(td.last_lat)) *
        cos(radians(td.last_lng) - radians(p_lng)) +
        sin(radians(p_lat)) * sin(radians(td.last_lat))
      )
    ) <= p_radius_km
  ORDER BY distance_km ASC;
END;
$$;