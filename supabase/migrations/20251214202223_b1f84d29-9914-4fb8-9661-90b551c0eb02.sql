-- Corriger les vendor_agents qui ont vendor_id = user_id au lieu de vendors.id
UPDATE public.vendor_agents va
SET vendor_id = v.id
FROM public.vendors v
WHERE va.vendor_id = v.user_id
  AND va.vendor_id != v.id;

-- Log pour vérification
DO $$
DECLARE
  updated_count INTEGER;
BEGIN
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RAISE NOTICE 'Corrected % vendor_agents with wrong vendor_id', updated_count;
END $$;