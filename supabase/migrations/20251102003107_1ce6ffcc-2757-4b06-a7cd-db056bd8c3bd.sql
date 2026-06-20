-- Ajouter les colonnes pour l'annulation de courses
ALTER TABLE public.taxi_trips
ADD COLUMN IF NOT EXISTS cancel_reason TEXT,
ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMP WITH TIME ZONE;

-- Ajouter un index pour les recherches
CREATE INDEX IF NOT EXISTS idx_taxi_trips_cancelled_at ON public.taxi_trips(cancelled_at);

-- Corriger les politiques RLS pour taxi_ride_tracking pour permettre aux conducteurs d'insérer des positions
DROP POLICY IF EXISTS "Conducteurs peuvent insérer leurs positions" ON public.taxi_ride_tracking;

CREATE POLICY "Conducteurs peuvent insérer leurs positions"
ON public.taxi_ride_tracking
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.taxi_trips
    WHERE taxi_trips.id = taxi_ride_tracking.ride_id
    AND taxi_trips.driver_id = auth.uid()
  )
);