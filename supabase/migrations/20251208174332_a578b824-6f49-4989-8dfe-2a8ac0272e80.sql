-- Nettoyer les anciennes livraisons invalides "assigned" sans données valides
-- (probablement du test/développement)
UPDATE deliveries 
SET status = 'cancelled',
    cancelled_at = NOW(),
    cancel_reason = 'Données incomplètes - nettoyage système'
WHERE status IN ('assigned', 'pending', 'picked_up', 'in_transit')
  AND (vendor_name IS NULL OR customer_name IS NULL)
  AND created_at < NOW() - INTERVAL '7 days';

-- Supprimer les livraisons vraiment anciennes sans données
DELETE FROM deliveries 
WHERE (vendor_name IS NULL AND customer_name IS NULL)
  AND created_at < NOW() - INTERVAL '30 days';