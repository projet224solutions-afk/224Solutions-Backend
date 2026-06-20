-- Mettre à jour la contrainte vendors_service_type_check avec les codes service_types
ALTER TABLE public.vendors DROP CONSTRAINT IF EXISTS vendors_service_type_check;

ALTER TABLE public.vendors ADD CONSTRAINT vendors_service_type_check 
CHECK (service_type = ANY (ARRAY[
  'wholesale'::text, 
  'retail'::text, 
  'mixed'::text,
  -- Codes alignés avec service_types.code
  'ecommerce'::text,
  'restaurant'::text,
  'beaute'::text,
  'reparation'::text,
  'location'::text,
  'menage'::text,
  'livraison'::text,
  'media'::text,
  'education'::text,
  'sante'::text,
  'voyage'::text,
  'freelance'::text,
  'construction'::text,
  'agriculture'::text,
  'informatique'::text,
  -- Legacy values
  'boutique'::text,
  'salon_coiffure'::text,
  'garage_auto'::text,
  'immobilier'::text,
  'services_pro'::text,
  'photographe'::text,
  'autre'::text
]));