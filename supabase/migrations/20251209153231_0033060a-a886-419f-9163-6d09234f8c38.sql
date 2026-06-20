-- Ajouter la colonne driver_payment_method à la table deliveries
ALTER TABLE public.deliveries 
ADD COLUMN IF NOT EXISTS driver_payment_method TEXT DEFAULT 'cash';

-- Ajouter un commentaire pour documenter la colonne
COMMENT ON COLUMN public.deliveries.driver_payment_method IS 'Méthode de paiement du livreur: cash ou wallet';