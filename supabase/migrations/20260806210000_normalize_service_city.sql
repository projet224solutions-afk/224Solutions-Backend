-- ═══════════════════════════════════════════════════════════════════════════
-- PROXIMITÉ — normaliser la ville des services À LA SOURCE (fin des doublons « coyah »/« Coyah »).
-- La ville est saisie librement à la création → variantes de casse produisant 2 chips distinctes.
-- (1) Nettoyage des valeurs existantes : initcap(lower(trim)) — testé identité sur les valeurs
--     réelles (Conakry/Coyah/Coyah Centre/Préfecture De Coyah restent inchangées).
-- (2) Trigger BEFORE INSERT/UPDATE : normalise à chaque écriture → plus jamais de dérive.
-- ═══════════════════════════════════════════════════════════════════════════

UPDATE public.professional_services
SET city = initcap(lower(btrim(city)))
WHERE city IS NOT NULL AND btrim(city) <> '' AND city <> initcap(lower(btrim(city)));

CREATE OR REPLACE FUNCTION public.normalize_service_city()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.city IS NOT NULL AND btrim(NEW.city) <> '' THEN
    NEW.city := initcap(lower(btrim(NEW.city)));
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_normalize_service_city ON public.professional_services;
CREATE TRIGGER trg_normalize_service_city
  BEFORE INSERT OR UPDATE OF city ON public.professional_services
  FOR EACH ROW EXECUTE FUNCTION public.normalize_service_city();
