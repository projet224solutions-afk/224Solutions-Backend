-- Ajouter les colonnes de configuration de tarification de livraison pour les vendeurs
ALTER TABLE public.vendors 
ADD COLUMN IF NOT EXISTS delivery_base_price INTEGER DEFAULT 5000,
ADD COLUMN IF NOT EXISTS delivery_price_per_km INTEGER DEFAULT 1000,
ADD COLUMN IF NOT EXISTS delivery_rush_bonus INTEGER DEFAULT 2000,
ADD COLUMN IF NOT EXISTS delivery_enabled BOOLEAN DEFAULT true;

-- Commenter les colonnes
COMMENT ON COLUMN public.vendors.delivery_base_price IS 'Prix de base de livraison en GNF';
COMMENT ON COLUMN public.vendors.delivery_price_per_km IS 'Prix par kilomètre en GNF';
COMMENT ON COLUMN public.vendors.delivery_rush_bonus IS 'Bonus heure de pointe en GNF';
COMMENT ON COLUMN public.vendors.delivery_enabled IS 'Livraison activée pour ce vendeur';