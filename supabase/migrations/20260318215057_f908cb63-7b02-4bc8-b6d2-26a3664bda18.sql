
-- 1) Copier le GPS des vendors vers professional_services quand le même user_id existe
UPDATE public.professional_services ps
SET 
  latitude = v.latitude,
  longitude = v.longitude
FROM public.vendors v
WHERE ps.user_id = v.user_id
  AND (ps.latitude IS NULL OR ps.longitude IS NULL)
  AND v.latitude IS NOT NULL 
  AND v.longitude IS NOT NULL;

-- 2) Créer une fonction trigger pour synchroniser le GPS automatiquement
CREATE OR REPLACE FUNCTION public.sync_vendor_gps_to_services()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Quand un vendor met à jour ses coordonnées GPS, propager vers ses professional_services sans GPS
  IF (NEW.latitude IS NOT NULL AND NEW.longitude IS NOT NULL) 
     AND (OLD.latitude IS NULL OR OLD.longitude IS NULL 
          OR NEW.latitude != OLD.latitude OR NEW.longitude != OLD.longitude) THEN
    UPDATE public.professional_services
    SET latitude = NEW.latitude, longitude = NEW.longitude
    WHERE user_id = NEW.user_id
      AND (latitude IS NULL OR longitude IS NULL);
  END IF;
  RETURN NEW;
END;
$$;

-- 3) Créer le trigger sur la table vendors
DROP TRIGGER IF EXISTS trg_sync_vendor_gps ON public.vendors;
CREATE TRIGGER trg_sync_vendor_gps
  AFTER UPDATE OF latitude, longitude ON public.vendors
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_vendor_gps_to_services();

-- 4) Aussi synchroniser quand un professional_service est créé sans GPS
CREATE OR REPLACE FUNCTION public.auto_fill_service_gps()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.latitude IS NULL OR NEW.longitude IS NULL THEN
    SELECT v.latitude, v.longitude 
    INTO NEW.latitude, NEW.longitude
    FROM public.vendors v
    WHERE v.user_id = NEW.user_id
      AND v.latitude IS NOT NULL 
      AND v.longitude IS NOT NULL
    LIMIT 1;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_fill_service_gps ON public.professional_services;
CREATE TRIGGER trg_auto_fill_service_gps
  BEFORE INSERT ON public.professional_services
  FOR EACH ROW
  EXECUTE FUNCTION public.auto_fill_service_gps();
