-- Ajouter les champs manquants à la table registered_motos
ALTER TABLE registered_motos
ADD COLUMN IF NOT EXISTS owner_name TEXT,
ADD COLUMN IF NOT EXISTS owner_phone TEXT,
ADD COLUMN IF NOT EXISTS vest_number TEXT,
ADD COLUMN IF NOT EXISTS plate_number TEXT;

COMMENT ON COLUMN registered_motos.owner_name IS 'Nom du propriétaire de la moto';
COMMENT ON COLUMN registered_motos.owner_phone IS 'Téléphone du propriétaire';
COMMENT ON COLUMN registered_motos.vest_number IS 'Numéro de gilet du conducteur';
COMMENT ON COLUMN registered_motos.plate_number IS 'Numéro de plaque de la moto';