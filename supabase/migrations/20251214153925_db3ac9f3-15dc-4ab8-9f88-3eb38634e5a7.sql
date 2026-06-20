-- Supprimer le trigger problématique qui utilise vehicle_id inexistant
DROP TRIGGER IF EXISTS check_vehicle_stolen_on_trip ON taxi_trips;

-- Note: La fonction check_vehicle_not_stolen est conçue pour la table vehicles, 
-- pas pour taxi_trips qui n'a pas de colonne vehicle_id