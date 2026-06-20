-- Créer les professional_services manquants pour les vendors existants
-- en mappant leur service_type legacy vers les codes service_types

INSERT INTO public.professional_services (user_id, service_type_id, business_name, description, address, phone, email, city, status)
SELECT 
  v.user_id,
  COALESCE(
    -- Mapping direct si le service_type correspond à un code
    (SELECT id FROM service_types WHERE code = v.service_type AND is_active = true LIMIT 1),
    -- Mapping legacy vers ecommerce par défaut
    (SELECT id FROM service_types WHERE code = 'ecommerce' AND is_active = true LIMIT 1)
  ) as service_type_id,
  v.business_name,
  v.description,
  v.address,
  v.phone,
  v.email,
  v.city,
  'active'
FROM vendors v
WHERE v.is_active = true
  AND v.user_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM professional_services ps WHERE ps.user_id = v.user_id
  );