-- Fix business_type constraint to allow 'service'
ALTER TABLE vendors DROP CONSTRAINT IF EXISTS vendors_business_type_check;
ALTER TABLE vendors ADD CONSTRAINT vendors_business_type_check 
  CHECK (business_type IN ('physical', 'digital', 'hybrid', 'service'));

-- Fix service_type constraint to include missing codes
ALTER TABLE vendors DROP CONSTRAINT IF EXISTS vendors_service_type_check;
ALTER TABLE vendors ADD CONSTRAINT vendors_service_type_check 
  CHECK (service_type IN (
    'wholesale','retail','mixed','ecommerce','restaurant','beaute',
    'reparation','location','menage','livraison','media','education',
    'sante','voyage','freelance','construction','agriculture',
    'informatique','boutique','salon_coiffure','garage_auto',
    'immobilier','services_pro','photographe','autre',
    'sport','vtc','maison','general','digital_livre',
    'digital_logiciel','dropshipping'
  ));