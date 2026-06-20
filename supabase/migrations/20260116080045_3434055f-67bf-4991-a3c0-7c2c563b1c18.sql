-- Rendre merchant_id nullable pour les produits système d'affiliation
ALTER TABLE digital_products ALTER COLUMN merchant_id DROP NOT NULL;

-- Supprimer la contrainte FK existante si elle existe
ALTER TABLE digital_products DROP CONSTRAINT IF EXISTS digital_products_merchant_id_fkey;