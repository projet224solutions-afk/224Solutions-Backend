-- Ajouter les colonnes manquantes à virtual_cards
ALTER TABLE virtual_cards 
ADD COLUMN IF NOT EXISTS daily_limit NUMERIC DEFAULT 500000,
ADD COLUMN IF NOT EXISTS monthly_limit NUMERIC DEFAULT 2000000;

-- Mettre à jour les cartes existantes
UPDATE virtual_cards 
SET daily_limit = 500000, monthly_limit = 2000000
WHERE daily_limit IS NULL OR monthly_limit IS NULL;