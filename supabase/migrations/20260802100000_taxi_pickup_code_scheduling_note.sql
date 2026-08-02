-- ═══════════════════════════════════════════════════════════════════════════════
-- TAXI NIVEAU UBER — Phase 0 : code de prise en charge + réservation planifiée + note chauffeur
-- ═══════════════════════════════════════════════════════════════════════════════
-- Livré en FICHIER — NON exécuté sans validation PDG (règle SQL 224).
--
-- Ajoute, SANS toucher au pricing serveur (calculate_taxi_fare / create_taxi_ride restent la vérité) :
--   1. Colonnes taxi_trips : scheduled_at (planif RÉELLE, corrige le state mort), rider_note (note au
--      chauffeur), driver_arrived_at (moment « chauffeur arrivé »).
--   2. Table SÉPARÉE taxi_pickup_codes (RLS : SEUL le client voit le code) — le code n'est JAMAIS lisible
--      par le chauffeur (pas une colonne de taxi_trips qu'un select * exposerait). Généré à l'ACCEPTATION.
--   3. RPC verify_taxi_pickup_code : le chauffeur saisit le code → démarre la course (anti-prise en charge
--      frauduleuse). IDOR-proof (auth.uid() = driver_id), même patron que update_taxi_trip_status.
--   4. RPC mark_taxi_arrived : le chauffeur signale « je suis arrivé » (déclenche l'affichage du code côté
--      client + la bannière « chauffeur arrivé »).
--   5. Sync metadata → colonnes à l'insertion (scheduled_at / rider_note passés via p_metadata de
--      create_taxi_ride → AUCUN changement de signature de la RPC de création).

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Colonnes taxi_trips
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.taxi_trips
  ADD COLUMN IF NOT EXISTS scheduled_at      timestamptz,
  ADD COLUMN IF NOT EXISTS rider_note        text,
  ADD COLUMN IF NOT EXISTS driver_arrived_at timestamptz;

COMMENT ON COLUMN public.taxi_trips.scheduled_at      IS 'Course planifiée : horaire souhaité (null = immédiate).';
COMMENT ON COLUMN public.taxi_trips.rider_note        IS 'Note du client au chauffeur (ex. « devant la pharmacie »).';
COMMENT ON COLUMN public.taxi_trips.driver_arrived_at IS 'Horodatage « chauffeur arrivé au point de départ ».';

-- Index partiel : lister les courses planifiées à venir (dispatch au bon moment).
CREATE INDEX IF NOT EXISTS idx_taxi_trips_scheduled
  ON public.taxi_trips (scheduled_at)
  WHERE scheduled_at IS NOT NULL AND status = 'requested';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Code de prise en charge — table SÉPARÉE, invisible du chauffeur (RLS client-only)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.taxi_pickup_codes (
  ride_id    uuid PRIMARY KEY REFERENCES public.taxi_trips(id) ON DELETE CASCADE,
  code       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.taxi_pickup_codes ENABLE ROW LEVEL SECURITY;

-- SEUL le client propriétaire de la course peut LIRE le code. Le chauffeur n'a AUCUNE policy → invisible.
DROP POLICY IF EXISTS pickup_code_select_customer ON public.taxi_pickup_codes;
CREATE POLICY pickup_code_select_customer ON public.taxi_pickup_codes
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.taxi_trips t
    WHERE t.id = taxi_pickup_codes.ride_id
      AND t.customer_id = auth.uid()
  ));

-- Écriture réservée au trigger SECURITY DEFINER / service_role (aucune policy INSERT/UPDATE pour authenticated).
REVOKE ALL ON public.taxi_pickup_codes FROM anon;
GRANT SELECT ON public.taxi_pickup_codes TO authenticated;
GRANT ALL ON public.taxi_pickup_codes TO service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Trigger : génère le code (4 chiffres) à l'ACCEPTATION de la course
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.taxi_generate_pickup_code()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER              -- écrit dans taxi_pickup_codes même si l'accept vient d'un chauffeur (authenticated)
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'accepted' AND COALESCE(OLD.status, '') <> 'accepted' THEN
    INSERT INTO public.taxi_pickup_codes (ride_id, code)
    VALUES (NEW.id, lpad((floor(random() * 10000))::int::text, 4, '0'))
    ON CONFLICT (ride_id) DO NOTHING;   -- idempotent : jamais régénéré
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_taxi_generate_pickup_code ON public.taxi_trips;
CREATE TRIGGER trg_taxi_generate_pickup_code
  AFTER UPDATE OF status ON public.taxi_trips
  FOR EACH ROW
  EXECUTE FUNCTION public.taxi_generate_pickup_code();

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Trigger : sync metadata → colonnes dédiées à l'INSERT (planif + note sans changer create_taxi_ride)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.taxi_trips_sync_meta_columns()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.scheduled_at IS NULL AND NEW.metadata ? 'scheduled_at'
     AND NULLIF(NEW.metadata ->> 'scheduled_at', '') IS NOT NULL THEN
    BEGIN
      NEW.scheduled_at := (NEW.metadata ->> 'scheduled_at')::timestamptz;
    EXCEPTION WHEN others THEN
      NEW.scheduled_at := NULL;   -- horaire invalide → ignoré, jamais de crash d'insertion
    END;
  END IF;

  IF NEW.rider_note IS NULL AND NEW.metadata ? 'rider_note' THEN
    NEW.rider_note := NULLIF(btrim(NEW.metadata ->> 'rider_note'), '');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_taxi_trips_sync_meta ON public.taxi_trips;
CREATE TRIGGER trg_taxi_trips_sync_meta
  BEFORE INSERT ON public.taxi_trips
  FOR EACH ROW
  EXECUTE FUNCTION public.taxi_trips_sync_meta_columns();

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. RPC : le chauffeur signale son arrivée (déclenche l'affichage du code côté client)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mark_taxi_arrived(p_ride_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver uuid := auth.uid();
  v_ride   record;
BEGIN
  IF v_driver IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED');
  END IF;

  SELECT id, status, driver_id INTO v_ride
  FROM public.taxi_trips WHERE id = p_ride_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'RIDE_NOT_FOUND');
  END IF;
  IF v_ride.driver_id IS DISTINCT FROM v_driver THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_YOUR_RIDE');
  END IF;
  IF v_ride.status NOT IN ('accepted', 'arriving') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATE');
  END IF;

  UPDATE public.taxi_trips
    SET status = 'arriving',
        driver_arrived_at = COALESCE(driver_arrived_at, NOW()),
        updated_at = NOW()
    WHERE id = p_ride_id AND driver_id = v_driver;

  RETURN jsonb_build_object('success', true, 'ride_id', p_ride_id, 'driver_arrived', true);
END;
$$;

REVOKE ALL ON FUNCTION public.mark_taxi_arrived(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_taxi_arrived(uuid) TO authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. RPC : vérification du code de prise en charge → démarre la course
--    IDOR-proof (auth.uid() = driver_id). Le code est lu ICI (SECURITY DEFINER), jamais exposé au chauffeur.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.verify_taxi_pickup_code(p_ride_id uuid, p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver uuid := auth.uid();
  v_ride   record;
  v_code   text;
BEGIN
  IF v_driver IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED');
  END IF;

  SELECT id, status, driver_id INTO v_ride
  FROM public.taxi_trips WHERE id = p_ride_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'RIDE_NOT_FOUND');
  END IF;
  IF v_ride.driver_id IS DISTINCT FROM v_driver THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_YOUR_RIDE');
  END IF;
  IF v_ride.status NOT IN ('accepted', 'arriving') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATE');
  END IF;

  SELECT code INTO v_code FROM public.taxi_pickup_codes WHERE ride_id = p_ride_id;
  IF v_code IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_CODE');
  END IF;
  IF btrim(COALESCE(p_code, '')) IS DISTINCT FROM v_code THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PICKUP_CODE');
  END IF;

  UPDATE public.taxi_trips
    SET status = 'in_progress',
        started_at = COALESCE(started_at, NOW()),
        driver_arrived_at = COALESCE(driver_arrived_at, NOW()),
        updated_at = NOW()
    WHERE id = p_ride_id AND driver_id = v_driver;

  RETURN jsonb_build_object('success', true, 'ride_id', p_ride_id, 'new_status', 'in_progress');
END;
$$;

REVOKE ALL ON FUNCTION public.verify_taxi_pickup_code(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.verify_taxi_pickup_code(uuid, text) TO authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════════
-- FIN — vérifs post-application suggérées (à lancer après validation) :
--   • Accepter une course → 1 ligne dans taxi_pickup_codes (code à 4 chiffres).
--   • En tant que CHAUFFEUR : SELECT sur taxi_pickup_codes → 0 ligne (RLS). En tant que CLIENT → 1 ligne.
--   • verify_taxi_pickup_code(ride, mauvais_code) → INVALID_PICKUP_CODE ; (ride, bon_code) → in_progress.
--   • create_taxi_ride(..., p_metadata => '{"scheduled_at":"...","rider_note":"..."}') → colonnes remplies.
-- ═══════════════════════════════════════════════════════════════════════════════
