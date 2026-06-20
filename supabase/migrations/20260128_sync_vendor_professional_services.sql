-- Migration: Synchronisation automatique vendor ↔ professional_services
-- Date: 2026-01-XX
-- Description: Crée un trigger pour synchroniser le service_type entre vendors et professional_services

-- ============================================================================
-- PARTIE 1: FONCTION DE SYNCHRONISATION
-- ============================================================================

CREATE OR REPLACE FUNCTION sync_vendor_service_type()
RETURNS TRIGGER AS $$
DECLARE
  service_code VARCHAR;
BEGIN
  -- Récupérer le code du service_type à partir de l'ID
  SELECT code INTO service_code
  FROM service_types
  WHERE id = NEW.service_type_id;
  
  -- Si le code est trouvé, mettre à jour le vendor
  IF service_code IS NOT NULL THEN
    UPDATE vendors
    SET service_type = service_code,
        updated_at = NOW()
    WHERE user_id = NEW.user_id;
    
    -- Log pour debug
    RAISE NOTICE 'Synchronisation: user_id=%, service_type=%', NEW.user_id, service_code;
  ELSE
    RAISE WARNING 'Service type ID % non trouvé dans service_types', NEW.service_type_id;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- PARTIE 2: TRIGGERS
-- ============================================================================

-- Trigger après insertion d'un nouveau professional_service
DROP TRIGGER IF EXISTS sync_vendor_service_after_insert ON professional_services;
CREATE TRIGGER sync_vendor_service_after_insert
AFTER INSERT ON professional_services
FOR EACH ROW
EXECUTE FUNCTION sync_vendor_service_type();

-- Trigger après modification du service_type_id
DROP TRIGGER IF EXISTS sync_vendor_service_after_update ON professional_services;
CREATE TRIGGER sync_vendor_service_after_update
AFTER UPDATE OF service_type_id ON professional_services
FOR EACH ROW
WHEN (OLD.service_type_id IS DISTINCT FROM NEW.service_type_id)
EXECUTE FUNCTION sync_vendor_service_type();

-- ============================================================================
-- PARTIE 3: SYNCHRONISATION DES DONNÉES EXISTANTES
-- ============================================================================

-- Synchroniser tous les vendors qui ont un professional_service actif
-- mais dont le service_type ne correspond pas
DO $$
DECLARE
  sync_count INTEGER := 0;
BEGIN
  UPDATE vendors v
  SET service_type = st.code,
      updated_at = NOW()
  FROM professional_services ps
  JOIN service_types st ON st.id = ps.service_type_id
  WHERE ps.user_id = v.user_id
    AND ps.status = 'active'
    AND (v.service_type IS NULL OR v.service_type != st.code);
  
  GET DIAGNOSTICS sync_count = ROW_COUNT;
  
  RAISE NOTICE '✅ % vendors synchronisés avec leurs professional_services', sync_count;
END $$;

-- ============================================================================
-- PARTIE 4: COMMENTAIRES ET DOCUMENTATION
-- ============================================================================

COMMENT ON FUNCTION sync_vendor_service_type() IS 
  'Synchronise automatiquement le champ service_type de la table vendors 
   avec le service_type_id de professional_services lorsqu''un service 
   professionnel est créé ou modifié.';

COMMENT ON TRIGGER sync_vendor_service_after_insert ON professional_services IS
  'Synchronise vendor.service_type après création d''un professional_service';

COMMENT ON TRIGGER sync_vendor_service_after_update ON professional_services IS
  'Synchronise vendor.service_type après modification du service_type_id';

-- ============================================================================
-- TESTS DE VALIDATION
-- ============================================================================

-- Pour tester après application de la migration:
/*
-- 1. Créer un test professional_service
INSERT INTO professional_services (
  user_id, 
  service_type_id, 
  business_name, 
  status
) VALUES (
  '00000000-0000-0000-0000-000000000001', -- Remplacer par un vrai user_id
  (SELECT id FROM service_types WHERE code = 'restaurant' LIMIT 1),
  'Restaurant Test',
  'active'
);

-- 2. Vérifier que vendors.service_type est mis à jour
SELECT 
  v.id,
  v.business_name,
  v.service_type as vendor_service_type,
  st.code as professional_service_type
FROM vendors v
JOIN professional_services ps ON ps.user_id = v.user_id
JOIN service_types st ON st.id = ps.service_type_id
WHERE v.user_id = '00000000-0000-0000-0000-000000000001';

-- 3. Tester la modification
UPDATE professional_services
SET service_type_id = (SELECT id FROM service_types WHERE code = 'beaute' LIMIT 1)
WHERE user_id = '00000000-0000-0000-0000-000000000001';

-- 4. Vérifier que le vendor est mis à jour
SELECT service_type FROM vendors 
WHERE user_id = '00000000-0000-0000-0000-000000000001';
-- Devrait afficher 'beaute'
*/

-- ============================================================================
-- ROLLBACK
-- ============================================================================

-- Pour annuler cette migration si nécessaire:
/*
DROP TRIGGER IF EXISTS sync_vendor_service_after_insert ON professional_services;
DROP TRIGGER IF EXISTS sync_vendor_service_after_update ON professional_services;
DROP FUNCTION IF EXISTS sync_vendor_service_type();
*/
