-- ============================================================================
-- LIEUX LOCAUX AUTO-APPRIS — précision destination pour la Guinée
-- ============================================================================
-- Problème : Google Places ne connaît pas les lieux péri-urbains guinéens
-- (Manéah Marché Nènè, Coyah Préfecture…). Solution : l'app APPREND le vrai GPS
-- de chaque lieu nommé à partir des courses réellement terminées là-bas.
--   - Trigger AFTER UPDATE(status='completed') sur taxi_trips
--   - vrai point = dernier taxi_ride_tracking du conducteur (sinon coord réservation)
--   - moyenne pondérée → la position se précise avec l'usage
-- ============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS unaccent;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Table
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.local_places (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text NOT NULL,                 -- nom affiché (ex: "Manéah Marché Nènè")
  name_normalized text NOT NULL,                 -- minuscule + sans accents (recherche/dédup)
  latitude        double precision NOT NULL,
  longitude       double precision NOT NULL,
  usage_count     integer NOT NULL DEFAULT 1,
  commune         text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_local_places_norm ON public.local_places (name_normalized);

ALTER TABLE public.local_places ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS local_places_read ON public.local_places;
CREATE POLICY local_places_read ON public.local_places
  FOR SELECT TO authenticated USING (true);   -- écriture uniquement via RPC SECURITY DEFINER

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Normalisation (minuscule, sans accents, trim)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.normalize_place_name(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT trim(lower(public.unaccent(coalesce(p, ''))));
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Apprentissage : upsert avec moyenne pondérée des coordonnées
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.learn_local_place(
  p_name text, p_lat double precision, p_lng double precision
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_norm text := public.normalize_place_name(p_name);
  v_row  record;
BEGIN
  -- garde-fous : nom utile + coordonnées dans les bornes de la Guinée
  IF v_norm = '' OR length(v_norm) < 3 THEN RETURN; END IF;
  IF p_lat IS NULL OR p_lng IS NULL THEN RETURN; END IF;
  IF p_lat < 7 OR p_lat > 13 OR p_lng < -15 OR p_lng > -7 THEN RETURN; END IF;

  SELECT * INTO v_row FROM public.local_places
  WHERE name_normalized = v_norm LIMIT 1 FOR UPDATE;

  IF FOUND THEN
    UPDATE public.local_places
    SET latitude    = (latitude  * usage_count + p_lat) / (usage_count + 1),
        longitude   = (longitude * usage_count + p_lng) / (usage_count + 1),
        usage_count = usage_count + 1,
        updated_at  = now()
    WHERE id = v_row.id;
  ELSE
    INSERT INTO public.local_places (name, name_normalized, latitude, longitude)
    VALUES (trim(p_name), v_norm, p_lat, p_lng);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.learn_local_place(text, double precision, double precision) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.learn_local_place(text, double precision, double precision) TO authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Recherche : par contenu normalisé, les plus utilisés d'abord
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.search_local_places(p_query text, p_limit int DEFAULT 5)
RETURNS TABLE(id uuid, name text, latitude double precision, longitude double precision, usage_count int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT lp.id, lp.name, lp.latitude, lp.longitude, lp.usage_count
  FROM public.local_places lp
  WHERE public.normalize_place_name(p_query) <> ''
    AND lp.name_normalized ILIKE '%' || public.normalize_place_name(p_query) || '%'
  ORDER BY lp.usage_count DESC, lp.name ASC
  LIMIT LEAST(GREATEST(p_limit, 1), 10);
$$;
GRANT EXECUTE ON FUNCTION public.search_local_places(text, int) TO authenticated, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Trigger : apprendre le lieu d'arrivée à chaque course terminée
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.taxi_learn_dropoff_on_complete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_lat double precision;
  v_lng double precision;
BEGIN
  IF NEW.status = 'completed' AND COALESCE(OLD.status, '') <> 'completed'
     AND NEW.dropoff_address IS NOT NULL AND length(trim(NEW.dropoff_address)) >= 3 THEN
    -- vrai point d'arrivée = dernier point de tracking du conducteur
    SELECT latitude, longitude INTO v_lat, v_lng
    FROM public.taxi_ride_tracking WHERE ride_id = NEW.id
    ORDER BY created_at DESC LIMIT 1;
    -- repli : coordonnées de réservation
    IF v_lat IS NULL THEN v_lat := NEW.dropoff_lat; v_lng := NEW.dropoff_lng; END IF;
    IF v_lat IS NOT NULL AND v_lng IS NOT NULL THEN
      PERFORM public.learn_local_place(NEW.dropoff_address, v_lat, v_lng);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_taxi_learn_dropoff ON public.taxi_trips;
CREATE TRIGGER trg_taxi_learn_dropoff
  AFTER UPDATE OF status ON public.taxi_trips
  FOR EACH ROW EXECUTE FUNCTION public.taxi_learn_dropoff_on_complete();

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Vérification atomique
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_tbl boolean; v_learn boolean; v_search boolean; v_trg boolean;
BEGIN
  SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name='local_places') INTO v_tbl;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname='learn_local_place') INTO v_learn;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname='search_local_places') INTO v_search;
  SELECT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='trg_taxi_learn_dropoff') INTO v_trg;
  IF NOT (v_tbl AND v_learn AND v_search AND v_trg) THEN
    RAISE EXCEPTION 'ÉCHEC lieux locaux — table=% learn=% search=% trigger=%', v_tbl, v_learn, v_search, v_trg;
  END IF;
  RAISE NOTICE '✅ LIEUX LOCAUX OK — table + 3 fonctions + trigger d''apprentissage';
END;
$$;

COMMIT;
