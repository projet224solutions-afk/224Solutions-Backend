
-- Désactiver les boutiques "Fusion Digitale" pour qu'elles ne soient plus visibles
UPDATE vendors 
SET is_active = false, updated_at = NOW() 
WHERE id IN ('9e622843-f7c1-4a05-95f2-69429ceac420', '7d05e14d-7edc-47fc-a10d-082dc0a16a49');

-- Désactiver tous leurs produits
UPDATE products 
SET is_active = false, updated_at = NOW() 
WHERE vendor_id IN ('9e622843-f7c1-4a05-95f2-69429ceac420', '7d05e14d-7edc-47fc-a10d-082dc0a16a49');
