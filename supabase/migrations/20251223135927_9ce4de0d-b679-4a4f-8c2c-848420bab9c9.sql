-- Ajouter les colonnes de géolocalisation et informations de boutique à la table vendors
ALTER TABLE public.vendors
ADD COLUMN IF NOT EXISTS latitude DECIMAL(10, 8),
ADD COLUMN IF NOT EXISTS longitude DECIMAL(11, 8),
ADD COLUMN IF NOT EXISTS city TEXT,
ADD COLUMN IF NOT EXISTS neighborhood TEXT,
ADD COLUMN IF NOT EXISTS business_type TEXT DEFAULT 'physical' CHECK (business_type IN ('physical', 'digital', 'hybrid')),
ADD COLUMN IF NOT EXISTS service_type TEXT DEFAULT 'retail' CHECK (service_type IN ('wholesale', 'retail', 'mixed'));

-- Ajouter des commentaires pour documentation
COMMENT ON COLUMN public.vendors.latitude IS 'Latitude GPS de la boutique';
COMMENT ON COLUMN public.vendors.longitude IS 'Longitude GPS de la boutique';
COMMENT ON COLUMN public.vendors.city IS 'Ville où se trouve la boutique';
COMMENT ON COLUMN public.vendors.neighborhood IS 'Quartier de la boutique';
COMMENT ON COLUMN public.vendors.business_type IS 'Type de boutique: physical (physique), digital (numérique), hybrid (les deux)';
COMMENT ON COLUMN public.vendors.service_type IS 'Type de service: wholesale (grossiste), retail (détaillant), mixed (les deux)';

-- Créer un index spatial pour optimiser les requêtes de proximité
CREATE INDEX IF NOT EXISTS idx_vendors_location ON public.vendors (latitude, longitude) WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

-- Index pour filtrer par type
CREATE INDEX IF NOT EXISTS idx_vendors_business_type ON public.vendors (business_type);
CREATE INDEX IF NOT EXISTS idx_vendors_service_type ON public.vendors (service_type);
CREATE INDEX IF NOT EXISTS idx_vendors_city ON public.vendors (city);