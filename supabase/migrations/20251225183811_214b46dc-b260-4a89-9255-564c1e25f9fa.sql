-- Ajouter les colonnes de géolocalisation à professional_services
ALTER TABLE public.professional_services
ADD COLUMN IF NOT EXISTS latitude DECIMAL(10, 8),
ADD COLUMN IF NOT EXISTS longitude DECIMAL(11, 8),
ADD COLUMN IF NOT EXISTS city VARCHAR(100),
ADD COLUMN IF NOT EXISTS neighborhood VARCHAR(100);

-- Index pour les recherches géographiques
CREATE INDEX IF NOT EXISTS idx_professional_services_location 
ON public.professional_services(latitude, longitude) 
WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

-- Commentaires
COMMENT ON COLUMN public.professional_services.latitude IS 'Latitude GPS du service professionnel';
COMMENT ON COLUMN public.professional_services.longitude IS 'Longitude GPS du service professionnel';