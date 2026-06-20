-- Supprimer les anciennes policies conflictuelles
DROP POLICY IF EXISTS "Drivers can accept and update deliveries" ON deliveries;
DROP POLICY IF EXISTS "Drivers update deliveries" ON deliveries;

-- Créer une policy unifiée pour les livreurs qui permet:
-- 1. D'accepter une livraison (status=pending ET driver_id IS NULL)
-- 2. De mettre à jour leurs propres livraisons assignées
CREATE POLICY "Drivers can accept available deliveries"
ON deliveries
FOR UPDATE
USING (
  -- Peut voir les livraisons en attente sans driver OU ses propres livraisons assignées
  (status = 'pending' AND driver_id IS NULL)
  OR (driver_id = auth.uid())
)
WITH CHECK (
  -- Après l'update, le driver_id doit être celui de l'utilisateur authentifié
  driver_id = auth.uid()
);