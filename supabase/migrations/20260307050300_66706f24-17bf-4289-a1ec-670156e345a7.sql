-- Ajouter les valeurs manquantes à l'enum user_role
ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'prestataire';
ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'bureau';
ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'vendor_agent';
ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'driver';