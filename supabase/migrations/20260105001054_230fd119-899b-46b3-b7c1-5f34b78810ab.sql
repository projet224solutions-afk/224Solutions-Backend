-- Supprimer l'ancienne contrainte
ALTER TABLE public.vendors DROP CONSTRAINT IF EXISTS vendors_service_type_check;

-- Ajouter la nouvelle contrainte avec toutes les valeurs de service autorisées
ALTER TABLE public.vendors ADD CONSTRAINT vendors_service_type_check 
CHECK (service_type = ANY (ARRAY[
  'wholesale'::text, 
  'retail'::text, 
  'mixed'::text,
  'boutique'::text,
  'restaurant'::text,
  'salon_coiffure'::text,
  'garage_auto'::text,
  'immobilier'::text,
  'services_pro'::text,
  'photographe'::text,
  'education'::text,
  'sante'::text,
  'voyage'::text,
  'autre'::text
]));