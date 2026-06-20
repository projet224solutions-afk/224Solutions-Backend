-- Supprimer le doublon professional_service pour l'utilisateur kafinma91
DELETE FROM professional_services 
WHERE id = '4f08ad5a-ab51-4154-a7e0-9f390672ed97';

-- Ajouter une contrainte unique pour éviter les doublons futurs
-- Un utilisateur ne peut avoir qu'UN seul service actif du même type
CREATE UNIQUE INDEX IF NOT EXISTS idx_professional_services_user_service_type 
ON professional_services (user_id, service_type_id) 
WHERE status = 'active';