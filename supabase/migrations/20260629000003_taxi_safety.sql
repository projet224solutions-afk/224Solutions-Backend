-- ════════════════════════════════════════════════════════════════════
-- PARTIE 5 — Sécurité du trajet : évènements SOS / partage + lien public.
-- Donne la persistance backend aux composants existants (TaxiMotoSOSButton,
-- ShareLocationButton, SOSMediaRecorder, LocationShareListener).
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.taxi_safety_events (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id     UUID NOT NULL REFERENCES public.taxi_trips(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL,
  event_type  TEXT NOT NULL CHECK (event_type IN ('sos','share_started','share_stopped')),
  lat         NUMERIC(10,7),
  lng         NUMERIC(10,7),
  metadata    JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_safety_ride ON public.taxi_safety_events (ride_id, created_at DESC);

ALTER TABLE public.taxi_safety_events ENABLE ROW LEVEL SECURITY;

-- Le client/chauffeur de la course peut lire ; insertion par l'intéressé lui-même.
DROP POLICY IF EXISTS safety_involved ON public.taxi_safety_events;
CREATE POLICY safety_involved ON public.taxi_safety_events
  FOR ALL TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM public.taxi_trips t
      WHERE t.id = ride_id
        AND (t.customer_id = auth.uid()
             OR auth.uid() IN (SELECT user_id FROM public.taxi_drivers WHERE id = t.driver_id))
    )
  )
  WITH CHECK (user_id = auth.uid());

-- Lien de partage public d'un trajet (token) : un proche suit la position live
-- en lecture seule via ce token (pas d'auth requise pour le proche).
ALTER TABLE public.taxi_trips
  ADD COLUMN IF NOT EXISTS share_token TEXT UNIQUE;

DO $$ BEGIN
  IF to_regclass('public.taxi_safety_events') IS NULL
  THEN RAISE EXCEPTION 'table taxi_safety_events absente'; END IF;
  RAISE NOTICE '✅ taxi_safety_events + share_token OK';
END; $$;

COMMIT;
