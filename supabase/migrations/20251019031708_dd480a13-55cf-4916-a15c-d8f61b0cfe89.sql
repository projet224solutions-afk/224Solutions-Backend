-- Ajouter les colonnes pays et ville à la table warehouses
ALTER TABLE warehouses 
ADD COLUMN IF NOT EXISTS country VARCHAR(100),
ADD COLUMN IF NOT EXISTS city VARCHAR(100);