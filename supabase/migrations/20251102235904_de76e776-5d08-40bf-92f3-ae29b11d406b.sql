
-- Supprimer l'ancienne policy incorrecte
DROP POLICY IF EXISTS "Drivers can update assigned rides" ON taxi_trips;

-- Créer une nouvelle policy correcte qui vérifie le user_id via la table taxi_drivers
CREATE POLICY "Drivers can update their assigned rides"
ON taxi_trips
FOR UPDATE
TO authenticated
USING (
  auth.uid() IN (
    SELECT user_id 
    FROM taxi_drivers 
    WHERE id = taxi_trips.driver_id
  )
)
WITH CHECK (
  auth.uid() IN (
    SELECT user_id 
    FROM taxi_drivers 
    WHERE id = taxi_trips.driver_id
  )
);

-- Corriger aussi la policy de tracking qui a le même problème
DROP POLICY IF EXISTS "Drivers can track their rides" ON taxi_ride_tracking;

CREATE POLICY "Drivers can insert ride tracking"
ON taxi_ride_tracking
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 
    FROM taxi_trips t
    JOIN taxi_drivers d ON d.id = t.driver_id
    WHERE t.id = taxi_ride_tracking.ride_id 
    AND d.user_id = auth.uid()
  )
);

-- Permettre aussi la lecture
CREATE POLICY "Drivers can view their ride tracking"
ON taxi_ride_tracking
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 
    FROM taxi_trips t
    JOIN taxi_drivers d ON d.id = t.driver_id
    WHERE t.id = taxi_ride_tracking.ride_id 
    AND d.user_id = auth.uid()
  )
);
