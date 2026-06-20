
-- =====================================================
-- MIGRATION: Index et Fonction Stats (corrigée)
-- =====================================================

-- 1. INDEX POUR PERFORMANCES
-- =====================================================
CREATE INDEX IF NOT EXISTS idx_taxi_drivers_bureau_status ON public.taxi_drivers(bureau_id, status);
CREATE INDEX IF NOT EXISTS idx_taxi_drivers_online_location ON public.taxi_drivers(is_online, last_lat, last_lng) WHERE is_online = true;
CREATE INDEX IF NOT EXISTS idx_taxi_trips_driver_status ON public.taxi_trips(driver_id, status);
CREATE INDEX IF NOT EXISTS idx_deliveries_driver_status ON public.deliveries(driver_id, status);
CREATE INDEX IF NOT EXISTS idx_deliveries_vendor_status ON public.deliveries(vendor_id, status);
CREATE INDEX IF NOT EXISTS idx_sos_alerts_taxi_driver_status ON public.sos_alerts(taxi_driver_id, status);

-- 2. FONCTION POUR STATISTIQUES TEMPS RÉEL BUREAU (corrigée)
-- =====================================================
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
    COALESCE((SELECT SUM(tt.final_price) FROM public.taxi_trips tt 
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

-- 3. TRIGGER AUTO-ASSIGNATION TAXI À BUREAU
-- =====================================================
CREATE OR REPLACE FUNCTION public.auto_assign_taxi_bureau()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  -- Si nouveau taxi sans bureau, assigner au premier bureau actif
  IF NEW.bureau_id IS NULL THEN
    NEW.bureau_id := (SELECT id FROM public.bureaus WHERE status = 'active' LIMIT 1);
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trigger_auto_assign_taxi_bureau ON public.taxi_drivers;
CREATE TRIGGER trigger_auto_assign_taxi_bureau
  BEFORE INSERT ON public.taxi_drivers
  FOR EACH ROW
  EXECUTE FUNCTION public.auto_assign_taxi_bureau();

-- 4. LIER LES TAXI-DRIVERS EXISTANTS QUI N'ONT PAS DE BUREAU
-- =====================================================
UPDATE public.taxi_drivers 
SET bureau_id = (SELECT id FROM public.bureaus WHERE status = 'active' LIMIT 1)
WHERE bureau_id IS NULL;
