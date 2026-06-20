-- Ajouter une politique RLS pour permettre aux conducteurs de voir les courses disponibles (requested)
-- Cela permet aux conducteurs de voir les courses en attente pour les accepter

CREATE POLICY "Drivers can view available rides"
ON public.taxi_trips
FOR SELECT
TO authenticated
USING (
  status = 'requested' 
  AND driver_id IS NULL
  AND EXISTS (
    SELECT 1 FROM taxi_drivers 
    WHERE taxi_drivers.user_id = auth.uid()
    AND taxi_drivers.is_online = true
  )
);

-- Commenter la politique pour plus de clarté
COMMENT ON POLICY "Drivers can view available rides" ON public.taxi_trips IS 
'Permet aux conducteurs en ligne de voir les courses disponibles (status=requested, driver_id=NULL) pour pouvoir les accepter';