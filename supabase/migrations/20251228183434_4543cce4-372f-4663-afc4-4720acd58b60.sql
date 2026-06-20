-- Correction de la fonction get_bureau_realtime_stats
-- Utilise price_total au lieu de final_price

CREATE OR REPLACE FUNCTION public.get_bureau_realtime_stats(p_bureau_id uuid)
RETURNS TABLE(
  total_drivers bigint,
  online_drivers bigint,
  on_trip_drivers bigint,
  today_rides bigint,
  today_earnings numeric,
  active_sos bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN QUERY
  SELECT 
    (SELECT COUNT(*) FROM public.taxi_drivers WHERE bureau_id = p_bureau_id) as total_drivers,
    (SELECT COUNT(*) FROM public.taxi_drivers WHERE bureau_id = p_bureau_id AND is_online = true) as online_drivers,
    (SELECT COUNT(*) FROM public.taxi_drivers WHERE bureau_id = p_bureau_id AND status = 'on_trip') as on_trip_drivers,
    (SELECT COUNT(*) FROM public.taxi_trips tt 
     JOIN public.taxi_drivers td ON tt.driver_id = td.id 
     WHERE td.bureau_id = p_bureau_id 
     AND tt.requested_at::date = CURRENT_DATE
     AND tt.status = 'completed') as today_rides,
    COALESCE((SELECT SUM(tt.price_total) FROM public.taxi_trips tt 
     JOIN public.taxi_drivers td ON tt.driver_id = td.id 
     WHERE td.bureau_id = p_bureau_id 
     AND tt.requested_at::date = CURRENT_DATE
     AND tt.status = 'completed'), 0) as today_earnings,
    (SELECT COUNT(*) FROM public.sos_alerts sa
     JOIN public.taxi_drivers td ON sa.taxi_driver_id = td.id
     WHERE td.bureau_id = p_bureau_id
     AND sa.status IN ('pending', 'acknowledged')) as active_sos;
END;
$function$;