-- Migration: Synchroniser service_types avec la page d'inscription
-- Date: 2026-01-11
-- Description: Assure que tous les services de l'inscription existent dans service_types

-- ============================================================================
-- PARTIE 1: CRÉER OU METTRE À JOUR LES SERVICE TYPES
-- ============================================================================

-- Fonction helper pour créer ou mettre à jour un service type
CREATE OR REPLACE FUNCTION upsert_service_type(
  p_code VARCHAR,
  p_name VARCHAR,
  p_description TEXT,
  p_category VARCHAR,
  p_commission_rate DECIMAL DEFAULT 10.0
) RETURNS VOID AS $$
BEGIN
  INSERT INTO service_types (code, name, description, category, commission_rate, is_active)
  VALUES (p_code, p_name, p_description, p_category, p_commission_rate, true)
  ON CONFLICT (code) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    category = EXCLUDED.category,
    is_active = true,
    updated_at = NOW();
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- PARTIE 2: INSÉRER TOUS LES SERVICES DE LA PAGE D'INSCRIPTION
-- ============================================================================

-- 1. E-commerce / Boutique
SELECT upsert_service_type(
  'ecommerce',
  'Boutique / E-commerce',
  'Vente de produits en ligne ou en magasin physique',
  'Commerce',
  8.0
);

-- 2. Restaurant / Alimentation
SELECT upsert_service_type(
  'restaurant',
  'Restaurant / Alimentation',
  'Service de restauration, vente de nourriture et boissons',
  'Alimentation',
  10.0
);

-- 3. Beauté & Bien-être
SELECT upsert_service_type(
  'beaute',
  'Beauté & Bien-être',
  'Coiffure, esthétique, massage et soins du corps',
  'Beauté',
  12.0
);

-- 4. Réparation / Mécanique
SELECT upsert_service_type(
  'reparation',
  'Réparation / Mécanique',
  'Réparation automobile, mécanique, électronique',
  'Réparation',
  15.0
);

-- 5. Location Immobilière
SELECT upsert_service_type(
  'location',
  'Location Immobilière',
  'Location d''appartements, maisons, bureaux',
  'Immobilier',
  5.0
);

-- 6. Ménage & Entretien
SELECT upsert_service_type(
  'menage',
  'Ménage & Entretien',
  'Services de nettoyage et d''entretien',
  'Services',
  12.0
);

-- 7. Livraison / Coursier
SELECT upsert_service_type(
  'livraison',
  'Livraison / Coursier',
  'Service de livraison à domicile, coursier',
  'Transport',
  10.0
);

-- 8. Photographe / Vidéaste
SELECT upsert_service_type(
  'media',
  'Photographe / Vidéaste',
  'Photographie, vidéographie, production audiovisuelle',
  'Média',
  15.0
);

-- 9. Éducation / Formation
SELECT upsert_service_type(
  'education',
  'Éducation / Formation',
  'Cours particuliers, formations professionnelles',
  'Éducation',
  10.0
);

-- 10. Santé & Bien-être
SELECT upsert_service_type(
  'sante',
  'Santé & Bien-être',
  'Services de santé, thérapies, consultation',
  'Santé',
  12.0
);

-- 11. Voyage / Tourisme
SELECT upsert_service_type(
  'voyage',
  'Voyage / Tourisme',
  'Agence de voyage, guide touristique, hébergement',
  'Tourisme',
  10.0
);

-- 12. Services Professionnels (Freelance)
SELECT upsert_service_type(
  'freelance',
  'Services Professionnels',
  'Consulting, design, développement, services B2B',
  'Professionnel',
  12.0
);

-- 13. Construction / BTP
SELECT upsert_service_type(
  'construction',
  'Construction / BTP',
  'Construction, rénovation, travaux publics',
  'Construction',
  15.0
);

-- 14. Agriculture
SELECT upsert_service_type(
  'agriculture',
  'Agriculture',
  'Production agricole, vente de produits fermiers',
  'Agriculture',
  8.0
);

-- 15. Informatique / Tech
SELECT upsert_service_type(
  'informatique',
  'Informatique / Tech',
  'Services informatiques, développement, support technique',
  'Technologie',
  12.0
);

-- 16. VTC / Transport (ancien service)
SELECT upsert_service_type(
  'vtc',
  'VTC / Transport',
  'Service de transport avec chauffeur',
  'Transport',
  15.0
);

-- ============================================================================
-- PARTIE 3: DÉSACTIVER LES SERVICES NON UTILISÉS
-- ============================================================================

-- Marquer comme inactifs les services qui ne sont plus dans la page d'inscription
UPDATE service_types
SET is_active = false, updated_at = NOW()
WHERE code NOT IN (
  'ecommerce', 'restaurant', 'beaute', 'reparation', 'location',
  'menage', 'livraison', 'media', 'education', 'sante',
  'voyage', 'freelance', 'construction', 'agriculture', 'informatique',
  'vtc', 'general'
);

-- ============================================================================
-- PARTIE 4: AJOUTER DES ICÔNES POUR CHAQUE SERVICE
-- ============================================================================

UPDATE service_types SET icon = 'ShoppingBag' WHERE code = 'ecommerce';
UPDATE service_types SET icon = 'Utensils' WHERE code = 'restaurant';
UPDATE service_types SET icon = 'Scissors' WHERE code = 'beaute';
UPDATE service_types SET icon = 'Car' WHERE code = 'reparation';
UPDATE service_types SET icon = 'Home' WHERE code = 'location';
UPDATE service_types SET icon = 'Sparkles' WHERE code = 'menage';
UPDATE service_types SET icon = 'Truck' WHERE code = 'livraison';
UPDATE service_types SET icon = 'Camera' WHERE code = 'media';
UPDATE service_types SET icon = 'GraduationCap' WHERE code = 'education';
UPDATE service_types SET icon = 'Stethoscope' WHERE code = 'sante';
UPDATE service_types SET icon = 'Plane' WHERE code = 'voyage';
UPDATE service_types SET icon = 'Wrench' WHERE code = 'freelance';
UPDATE service_types SET icon = 'HardHat' WHERE code = 'construction';
UPDATE service_types SET icon = 'Tractor' WHERE code = 'agriculture';
UPDATE service_types SET icon = 'Laptop' WHERE code = 'informatique';
UPDATE service_types SET icon = 'Car' WHERE code = 'vtc';

-- ============================================================================
-- PARTIE 5: VÉRIFICATIONS ET RAPPORT
-- ============================================================================

DO $$
DECLARE
  active_count INTEGER;
  inactive_count INTEGER;
  total_count INTEGER;
  rec RECORD;
BEGIN
  -- Compter les services
  SELECT COUNT(*) INTO active_count FROM service_types WHERE is_active = true;
  SELECT COUNT(*) INTO inactive_count FROM service_types WHERE is_active = false;
  SELECT COUNT(*) INTO total_count FROM service_types;
  
  -- Afficher le rapport
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE '📊 RAPPORT DE SYNCHRONISATION - Service Types';
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE 'Services actifs: %', active_count;
  RAISE NOTICE 'Services inactifs: %', inactive_count;
  RAISE NOTICE 'Total services: %', total_count;
  RAISE NOTICE '════════════════════════════════════════════════════';
  
  -- Afficher la liste des services actifs
  RAISE NOTICE 'Services actifs:';
  FOR rec IN 
    SELECT code, name, category 
    FROM service_types 
    WHERE is_active = true 
    ORDER BY category, name
  LOOP
    RAISE NOTICE '  ✓ % (%)', rec.name, rec.code;
  END LOOP;
  
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE '✅ Synchronisation terminée avec succès!';
END $$;

-- ============================================================================
-- PARTIE 6: COMMENTAIRES ET DOCUMENTATION
-- ============================================================================

COMMENT ON FUNCTION upsert_service_type IS
  'Crée ou met à jour un type de service. Utilisé pour synchroniser avec la page d''inscription.';

-- ============================================================================
-- PARTIE 7: NETTOYAGE DE LA FONCTION HELPER
-- ============================================================================

-- Supprimer la fonction temporaire (optionnel, vous pouvez la garder pour usage futur)
-- DROP FUNCTION IF EXISTS upsert_service_type;

-- ============================================================================
-- TESTS DE VALIDATION
-- ============================================================================

-- Pour tester après application de la migration:
/*
-- 1. Vérifier tous les services actifs
SELECT code, name, category, commission_rate, icon
FROM service_types
WHERE is_active = true
ORDER BY category, name;

-- 2. Vérifier qu'un code spécifique existe
SELECT * FROM service_types WHERE code = 'ecommerce';
SELECT * FROM service_types WHERE code = 'restaurant';
SELECT * FROM service_types WHERE code = 'beaute';

-- 3. Compter les services par catégorie
SELECT category, COUNT(*) as count
FROM service_types
WHERE is_active = true
GROUP BY category
ORDER BY count DESC;

-- 4. Vérifier les services sans icône
SELECT code, name
FROM service_types
WHERE is_active = true AND (icon IS NULL OR icon = '');
*/

-- ============================================================================
-- ROLLBACK
-- ============================================================================

-- Pour annuler cette migration si nécessaire:
/*
-- Réactiver tous les services
UPDATE service_types SET is_active = true;

-- Supprimer la fonction
DROP FUNCTION IF EXISTS upsert_service_type;
*/

-- ============================================================================
-- NOTES IMPORTANTES
-- ============================================================================

/*
Cette migration assure que:
1. Tous les services de MerchantOnboarding.tsx existent dans service_types
2. Les codes correspondent exactement (ecommerce, restaurant, beaute, etc.)
3. Les services non utilisés sont marqués comme inactifs (pas supprimés)
4. Chaque service a une icône correspondante
5. Les taux de commission sont définis par défaut
6. La migration est idempotente (peut être exécutée plusieurs fois)

Correspondance avec MerchantOnboarding.tsx:
✓ ecommerce → Boutique / E-commerce
✓ restaurant → Restaurant / Alimentation
✓ beaute → Beauté & Bien-être
✓ reparation → Réparation / Mécanique
✓ location → Location Immobilière
✓ menage → Ménage & Entretien
✓ livraison → Livraison / Coursier
✓ media → Photographe / Vidéaste
✓ education → Éducation / Formation
✓ sante → Santé & Bien-être
✓ voyage → Voyage / Tourisme
✓ freelance → Services Professionnels
✓ construction → Construction / BTP
✓ agriculture → Agriculture
✓ informatique → Informatique / Tech
✓ vtc → VTC / Transport (maintenu pour compatibilité)
*/
