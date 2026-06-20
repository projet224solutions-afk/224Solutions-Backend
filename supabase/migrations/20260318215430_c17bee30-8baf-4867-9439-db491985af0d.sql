
-- Trigger bidirectionnel: quand un professional_service reçoit du GPS, propager vers le vendor associé
CREATE OR REPLACE FUNCTION public.sync_service_gps_to_vendor()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF (NEW.latitude IS NOT NULL AND NEW.longitude IS NOT NULL) 
     AND (OLD.latitude IS NULL OR OLD.longitude IS NULL 
          OR NEW.latitude != OLD.latitude OR NEW.longitude != OLD.longitude) THEN
    UPDATE public.vendors
    SET latitude = NEW.latitude, longitude = NEW.longitude
    WHERE user_id = NEW.user_id
      AND (latitude IS NULL OR longitude IS NULL);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_service_gps_to_vendor ON public.professional_services;
CREATE TRIGGER trg_sync_service_gps_to_vendor
  AFTER UPDATE OF latitude, longitude ON public.professional_services
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_service_gps_to_vendor();

-- Auto-fill GPS pour les vendors à l'insertion (depuis professional_services du même user)
CREATE OR REPLACE FUNCTION public.auto_fill_vendor_gps()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.latitude IS NULL OR NEW.longitude IS NULL THEN
    SELECT ps.latitude, ps.longitude
    INTO NEW.latitude, NEW.longitude
    FROM public.professional_services ps
    WHERE ps.user_id = NEW.user_id
      AND ps.latitude IS NOT NULL
      AND ps.longitude IS NOT NULL
    LIMIT 1;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_fill_vendor_gps ON public.vendors;
CREATE TRIGGER trg_auto_fill_vendor_gps
  BEFORE INSERT ON public.vendors
  FOR EACH ROW
  EXECUTE FUNCTION public.auto_fill_vendor_gps();
