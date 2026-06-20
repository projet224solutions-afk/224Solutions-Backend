-- Ajouter le délai de livraison moyen aux vendeurs
ALTER TABLE public.vendors
  ADD COLUMN IF NOT EXISTS average_delivery_days INTEGER DEFAULT 3;

COMMENT ON COLUMN public.vendors.average_delivery_days IS 'Délai de livraison estimé en jours ouvrables (saisi par le vendeur)';

SELECT 'Colonne average_delivery_days ajoutée à vendors (défaut: 3 jours)' AS status;
