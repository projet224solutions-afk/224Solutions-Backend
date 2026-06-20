-- Migration: Contrainte unique pour éviter les doublons de services actifs
-- Date: 2026-01-XX
-- Description: Empêche un vendeur d'avoir plusieurs services actifs du même type

-- ============================================================================
-- PARTIE 1: NETTOYAGE DES DOUBLONS EXISTANTS
-- ============================================================================

-- Identifier et désactiver les doublons (garder le plus récent)
DO $$
DECLARE
  duplicate_count INTEGER := 0;
BEGIN
  -- Désactiver les doublons (garder le plus récent par user_id + service_type_id)
  WITH duplicates AS (
    SELECT 
      id,
      user_id,
      service_type_id,
      created_at,
      ROW_NUMBER() OVER (
        PARTITION BY user_id, service_type_id
        WHERE status = 'active'
        ORDER BY created_at DESC
      ) as row_num
    FROM professional_services
    WHERE status = 'active'
  )
  UPDATE professional_services ps
  SET 
    status = 'inactive',
    updated_at = NOW()
  FROM duplicates d
  WHERE ps.id = d.id 
    AND d.row_num > 1;
  
  GET DIAGNOSTICS duplicate_count = ROW_COUNT;
  
  IF duplicate_count > 0 THEN
    RAISE NOTICE '⚠️  % services dupliqués désactivés (les plus récents ont été conservés)', duplicate_count;
  ELSE
    RAISE NOTICE '✅ Aucun doublon trouvé';
  END IF;
END $$;

-- ============================================================================
-- PARTIE 2: CONTRAINTE UNIQUE (PostgreSQL 12+)
-- ============================================================================

-- Option 1: EXCLUDE constraint (plus flexible, PostgreSQL avec extension btree_gist)
-- Nécessite: CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Vérifier si l'extension existe, sinon la créer
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Créer la contrainte d'exclusion
-- (Permet plusieurs services du même type SI status != 'active')
DO $$
BEGIN
  ALTER TABLE professional_services
  ADD CONSTRAINT unique_active_user_service_type
  EXCLUDE USING gist (
    user_id WITH =,
    service_type_id WITH =
  ) WHERE (status = 'active');
  
  RAISE NOTICE '✅ Contrainte EXCLUDE créée avec succès';
EXCEPTION
  WHEN duplicate_object THEN
    RAISE NOTICE 'ℹ️  Contrainte unique_active_user_service_type existe déjà';
  WHEN undefined_file THEN
    -- L'extension btree_gist n'est pas disponible, utiliser un index unique
    RAISE NOTICE '⚠️  Extension btree_gist non disponible, utilisation d''un index unique à la place';
    
    -- Option 2: Index unique partiel (plus compatible)
    CREATE UNIQUE INDEX IF NOT EXISTS unique_active_service_per_user
    ON professional_services (user_id, service_type_id)
    WHERE status = 'active';
    
    RAISE NOTICE '✅ Index unique partiel créé';
END $$;

-- ============================================================================
-- PARTIE 3: INDEX POUR PERFORMANCE
-- ============================================================================

-- Index sur (user_id, service_type_id, status) pour les requêtes fréquentes
CREATE INDEX IF NOT EXISTS idx_professional_services_user_type_status 
ON professional_services (user_id, service_type_id, status);

-- Index sur status seul pour les requêtes admin
CREATE INDEX IF NOT EXISTS idx_professional_services_status 
ON professional_services (status);

-- ============================================================================
-- PARTIE 4: FONCTION DE VALIDATION (optionnelle)
-- ============================================================================

-- Fonction pour vérifier si un utilisateur peut créer un service
CREATE OR REPLACE FUNCTION can_create_professional_service(
  p_user_id UUID,
  p_service_type_id UUID
) RETURNS BOOLEAN AS $$
DECLARE
  existing_count INTEGER;
BEGIN
  -- Compter les services actifs du même type pour cet utilisateur
  SELECT COUNT(*) INTO existing_count
  FROM professional_services
  WHERE user_id = p_user_id
    AND service_type_id = p_service_type_id
    AND status = 'active';
  
  -- Retourner true si aucun service actif du même type n'existe
  RETURN existing_count = 0;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- PARTIE 5: COMMENTAIRES ET DOCUMENTATION
-- ============================================================================

COMMENT ON CONSTRAINT unique_active_user_service_type ON professional_services IS
  'Empêche un utilisateur d''avoir plusieurs services professionnels actifs du même type.
   Les services avec status != ''active'' ne sont pas contraints.';

COMMENT ON INDEX unique_active_service_per_user IS
  'Index unique partiel: un utilisateur ne peut avoir qu''un seul service actif par type.
   Alternative à EXCLUDE constraint si btree_gist n''est pas disponible.';

COMMENT ON FUNCTION can_create_professional_service IS
  'Vérifie si un utilisateur peut créer un nouveau service professionnel d''un type donné.
   Retourne false si l''utilisateur a déjà un service actif de ce type.';

-- ============================================================================
-- TESTS DE VALIDATION
-- ============================================================================

-- Pour tester après application de la migration:
/*
-- 1. Test de création d'un premier service (devrait réussir)
INSERT INTO professional_services (
  user_id, 
  service_type_id, 
  business_name, 
  status
) VALUES (
  '00000000-0000-0000-0000-000000000001',
  (SELECT id FROM service_types WHERE code = 'restaurant' LIMIT 1),
  'Mon Restaurant',
  'active'
);
-- ✅ Devrait réussir

-- 2. Test de création d'un doublon (devrait échouer)
INSERT INTO professional_services (
  user_id, 
  service_type_id, 
  business_name, 
  status
) VALUES (
  '00000000-0000-0000-0000-000000000001',
  (SELECT id FROM service_types WHERE code = 'restaurant' LIMIT 1),
  'Mon Deuxième Restaurant',
  'active'
);
-- ❌ Devrait échouer avec erreur 23505 (unique_violation)

-- 3. Test avec un service inactif (devrait réussir)
UPDATE professional_services
SET status = 'inactive'
WHERE user_id = '00000000-0000-0000-0000-000000000001'
  AND service_type_id = (SELECT id FROM service_types WHERE code = 'restaurant' LIMIT 1);

INSERT INTO professional_services (
  user_id, 
  service_type_id, 
  business_name, 
  status
) VALUES (
  '00000000-0000-0000-0000-000000000001',
  (SELECT id FROM service_types WHERE code = 'restaurant' LIMIT 1),
  'Nouveau Restaurant',
  'active'
);
-- ✅ Devrait réussir car l'ancien est inactif

-- 4. Test de la fonction de validation
SELECT can_create_professional_service(
  '00000000-0000-0000-0000-000000000001',
  (SELECT id FROM service_types WHERE code = 'beaute' LIMIT 1)
);
-- Devrait retourner true si pas de service beauté actif

-- 5. Statistiques après migration
SELECT 
  COUNT(*) as total_services,
  COUNT(*) FILTER (WHERE status = 'active') as active_services,
  COUNT(DISTINCT user_id) as unique_users,
  COUNT(DISTINCT service_type_id) as unique_types
FROM professional_services;
*/

-- ============================================================================
-- RAPPORT DE MIGRATION
-- ============================================================================

DO $$
DECLARE
  total_services INTEGER;
  active_services INTEGER;
  users_with_multiple INTEGER;
BEGIN
  -- Compter les services
  SELECT COUNT(*) INTO total_services FROM professional_services;
  SELECT COUNT(*) INTO active_services FROM professional_services WHERE status = 'active';
  
  -- Compter les utilisateurs avec plusieurs services
  SELECT COUNT(DISTINCT user_id) INTO users_with_multiple
  FROM (
    SELECT user_id
    FROM professional_services
    WHERE status = 'active'
    GROUP BY user_id
    HAVING COUNT(*) > 1
  ) sub;
  
  -- Afficher le rapport
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE '📊 RAPPORT DE MIGRATION - Contrainte Unique Services';
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE 'Total services: %', total_services;
  RAISE NOTICE 'Services actifs: %', active_services;
  RAISE NOTICE 'Utilisateurs avec plusieurs services actifs: %', users_with_multiple;
  RAISE NOTICE '════════════════════════════════════════════════════';
  
  IF users_with_multiple > 0 THEN
    RAISE WARNING 'Attention: % utilisateurs ont encore plusieurs services actifs!', users_with_multiple;
  ELSE
    RAISE NOTICE '✅ Aucun doublon détecté';
  END IF;
END $$;

-- ============================================================================
-- ROLLBACK
-- ============================================================================

-- Pour annuler cette migration si nécessaire:
/*
-- Supprimer la contrainte
ALTER TABLE professional_services DROP CONSTRAINT IF EXISTS unique_active_user_service_type;

-- Supprimer l'index
DROP INDEX IF EXISTS unique_active_service_per_user;

-- Supprimer les autres index
DROP INDEX IF EXISTS idx_professional_services_user_type_status;
DROP INDEX IF EXISTS idx_professional_services_status;

-- Supprimer la fonction
DROP FUNCTION IF EXISTS can_create_professional_service;
*/
