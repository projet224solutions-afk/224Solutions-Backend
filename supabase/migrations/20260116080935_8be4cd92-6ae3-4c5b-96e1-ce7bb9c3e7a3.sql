-- Supprimer les produits de démo que j'ai ajoutés par erreur
DELETE FROM digital_products WHERE merchant_id IS NULL;