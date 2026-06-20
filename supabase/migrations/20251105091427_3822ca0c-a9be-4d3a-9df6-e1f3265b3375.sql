-- Ajouter les colonnes remise et type_remise à la table payment_links
ALTER TABLE payment_links 
ADD COLUMN IF NOT EXISTS remise DECIMAL(10, 2) DEFAULT 0,
ADD COLUMN IF NOT EXISTS type_remise TEXT DEFAULT 'percentage' CHECK (type_remise IN ('percentage', 'fixed'));

-- Ajouter un commentaire pour documentation
COMMENT ON COLUMN payment_links.remise IS 'Montant de la remise appliquée (pourcentage ou montant fixe selon type_remise)';
COMMENT ON COLUMN payment_links.type_remise IS 'Type de remise: percentage (pourcentage) ou fixed (montant fixe)';