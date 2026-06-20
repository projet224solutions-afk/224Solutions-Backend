-- Nettoyage des données de démo
-- Supprime toutes les livraisons de test/démo

-- Supprimer les données de tracking associées aux livraisons
DELETE FROM delivery_tracking 
WHERE delivery_id IN (SELECT id FROM deliveries);

-- Supprimer toutes les livraisons
DELETE FROM deliveries;

-- Réinitialiser les compteurs si nécessaire
-- Les nouvelles livraisons auront des ID propres