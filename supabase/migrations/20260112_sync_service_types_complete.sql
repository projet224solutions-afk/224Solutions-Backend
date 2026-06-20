-- Migration: Synchronisation COMPLÈTE des service_types avec Auth.tsx et le module métier
-- Date: 2026-01-12
-- Description: Ajoute les nouveaux services manquants et corrige les incohérences

-- ============================================================================
-- PARTIE 1: FONCTION HELPER (si pas déjà créée)
-- ============================================================================

CREATE OR REPLACE FUNCTION upsert_service_type(
  p_code VARCHAR,
  p_name VARCHAR,
  p_description TEXT,
  p_category VARCHAR,
  p_commission_rate DECIMAL DEFAULT 10.0,
  p_icon VARCHAR DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
  INSERT INTO service_types (code, name, description, category, commission_rate, icon, is_active)
  VALUES (p_code, p_name, p_description, p_category, p_commission_rate, COALESCE(p_icon, 'Package'), true)
  ON CONFLICT (code) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    category = EXCLUDED.category,
    icon = COALESCE(EXCLUDED.icon, service_types.icon),
    is_active = true,
    updated_at = NOW();
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- PARTIE 2: NOUVEAUX SERVICES DEPUIS Auth.tsx (Services de Proximité)
-- ============================================================================

-- Sport & Fitness (présent dans Auth.tsx sous 'sport')
SELECT upsert_service_type(
  'sport',
  'Sport & Fitness',
  'Centre de fitness, coaching sportif, salles de sport',
  'Sport',
  10.0,
  'Dumbbell'
);

-- Maison & Déco (présent dans Auth.tsx sous 'maison')
SELECT upsert_service_type(
  'maison',
  'Maison & Déco',
  'Décoration intérieure, ameublement, design d''intérieur',
  'Maison',
  10.0,
  'Home'
);

-- ============================================================================
-- PARTIE 3: NOUVEAUX SERVICES - Produits Numériques (Auth.tsx)
-- ============================================================================

-- Logiciel / SaaS (présent dans Auth.tsx sous 'digital_logiciel')
SELECT upsert_service_type(
  'digital_logiciel',
  'Logiciel / SaaS',
  'Antivirus, logiciels professionnels, services SaaS',
  'Numérique',
  15.0,
  'Laptop'
);

-- Dropshipping (présent dans Auth.tsx sous 'dropshipping')
SELECT upsert_service_type(
  'dropshipping',
  'Dropshipping',
  'Vente de produits Amazon, AliExpress en dropshipping',
  'Commerce',
  12.0,
  'Package'
);

-- Livres numériques (présent dans Auth.tsx sous 'digital_livre')
SELECT upsert_service_type(
  'digital_livre',
  'Livres & eBooks',
  'eBooks, livres numériques, affiliation',
  'Numérique',
  8.0,
  'BookOpen'
);

-- ============================================================================
-- PARTIE 4: SERVICES EXISTANTS - Vérification et mise à jour
-- ============================================================================

-- S'assurer que tous les services de base sont présents avec les bons noms
SELECT upsert_service_type('ecommerce', 'Boutique / E-commerce', 'Vente de produits en ligne ou en magasin physique', 'Commerce', 8.0, 'ShoppingBag');
SELECT upsert_service_type('restaurant', 'Restaurant / Alimentation', 'Service de restauration, vente de nourriture et boissons', 'Alimentation', 10.0, 'Utensils');
SELECT upsert_service_type('beaute', 'Beauté & Bien-être', 'Coiffure, esthétique, massage et soins du corps', 'Beauté', 12.0, 'Scissors');
SELECT upsert_service_type('reparation', 'Réparation / Mécanique', 'Réparation automobile, mécanique, électronique', 'Réparation', 15.0, 'Wrench');
SELECT upsert_service_type('location', 'Location Immobilière', 'Location d''appartements, maisons, bureaux', 'Immobilier', 5.0, 'Home');
SELECT upsert_service_type('menage', 'Ménage & Entretien', 'Services de nettoyage et d''entretien', 'Services', 12.0, 'Sparkles');
SELECT upsert_service_type('livraison', 'Livraison / Coursier', 'Service de livraison à domicile, coursier', 'Transport', 10.0, 'Truck');
SELECT upsert_service_type('media', 'Photographe / Vidéaste', 'Photographie, vidéographie, production audiovisuelle', 'Média', 15.0, 'Camera');
SELECT upsert_service_type('education', 'Éducation / Formation', 'Cours particuliers, formations professionnelles', 'Éducation', 10.0, 'GraduationCap');
SELECT upsert_service_type('sante', 'Santé & Bien-être', 'Services de santé, thérapies, consultation', 'Santé', 12.0, 'Stethoscope');
SELECT upsert_service_type('voyage', 'Voyage / Tourisme', 'Agence de voyage, guide touristique, hébergement', 'Tourisme', 10.0, 'Plane');
SELECT upsert_service_type('freelance', 'Services Professionnels', 'Consulting, design, développement, services B2B', 'Professionnel', 12.0, 'Briefcase');
SELECT upsert_service_type('construction', 'Construction / BTP', 'Construction, rénovation, travaux publics', 'Construction', 15.0, 'HardHat');
SELECT upsert_service_type('agriculture', 'Agriculture', 'Production agricole, vente de produits fermiers', 'Agriculture', 8.0, 'Tractor');
SELECT upsert_service_type('informatique', 'Informatique / Tech', 'Services informatiques, développement, support technique', 'Technologie', 12.0, 'Laptop');
SELECT upsert_service_type('vtc', 'VTC / Transport', 'Service de transport avec chauffeur', 'Transport', 15.0, 'Car');

-- ============================================================================
-- PARTIE 5: DÉSACTIVER les services obsolètes (codes incorrects)
-- ============================================================================

-- Les anciens codes qui ne sont plus utilisés
UPDATE service_types 
SET is_active = false, updated_at = NOW()
WHERE code IN (
  'boutique',        -- remplacé par 'ecommerce'
  'salon_coiffure',  -- remplacé par 'beaute'
  'garage_auto',     -- remplacé par 'reparation'
  'immobilier',      -- remplacé par 'location'
  'services_pro',    -- remplacé par 'freelance'
  'photographe',     -- remplacé par 'media'
  'autre',           -- trop générique
  'fitness',         -- remplacé par 'sport'
  'coiffeur',        -- intégré dans 'beaute'
  'traiteur',        -- intégré dans 'restaurant'
  'mode',            -- intégré dans 'ecommerce'
  'coach'            -- intégré dans 'sport'
)
AND EXISTS (SELECT 1 FROM service_types WHERE code = 'ecommerce'); -- Vérification de sécurité

-- ============================================================================
-- PARTIE 6: TABLE DE MAPPING - Anciens codes vers nouveaux codes
-- ============================================================================

-- Créer une table de mapping pour la migration des données existantes
CREATE TABLE IF NOT EXISTS service_type_code_mapping (
  old_code VARCHAR(50) PRIMARY KEY,
  new_code VARCHAR(50) NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Insérer les correspondances
INSERT INTO service_type_code_mapping (old_code, new_code) VALUES
  ('boutique', 'ecommerce'),
  ('salon_coiffure', 'beaute'),
  ('garage_auto', 'reparation'),
  ('immobilier', 'location'),
  ('services_pro', 'freelance'),
  ('photographe', 'media'),
  ('fitness', 'sport'),
  ('coiffeur', 'beaute'),
  ('traiteur', 'restaurant'),
  ('mode', 'ecommerce'),
  ('coach', 'sport'),
  ('autre', 'ecommerce')
ON CONFLICT (old_code) DO UPDATE SET
  new_code = EXCLUDED.new_code;

-- ============================================================================
-- PARTIE 7: MIGRATION des vendors avec anciens codes
-- ============================================================================

-- Mettre à jour les vendors qui utilisent les anciens codes
UPDATE vendors v
SET service_type = m.new_code
FROM service_type_code_mapping m
WHERE v.service_type = m.old_code
AND v.service_type IS NOT NULL;

-- ============================================================================
-- PARTIE 8: MIGRATION des professional_services avec anciens service_type_id
-- ============================================================================

-- Mettre à jour les professional_services vers les nouveaux service_type_id
-- D'abord, récupérer les cas où le service_type actuel est obsolète
DO $$
DECLARE
  rec RECORD;
  new_type_id UUID;
BEGIN
  -- Pour chaque professional_service avec un service_type obsolète
  FOR rec IN 
    SELECT ps.id, ps.service_type_id, st.code as old_code, m.new_code
    FROM professional_services ps
    JOIN service_types st ON st.id = ps.service_type_id
    JOIN service_type_code_mapping m ON m.old_code = st.code
    WHERE st.is_active = false
  LOOP
    -- Récupérer le nouvel ID
    SELECT id INTO new_type_id 
    FROM service_types 
    WHERE code = rec.new_code AND is_active = true
    LIMIT 1;
    
    IF new_type_id IS NOT NULL THEN
      UPDATE professional_services
      SET service_type_id = new_type_id, updated_at = NOW()
      WHERE id = rec.id;
      
      RAISE NOTICE 'Migré professional_service % de % vers %', rec.id, rec.old_code, rec.new_code;
    END IF;
  END LOOP;
END $$;

-- ============================================================================
-- PARTIE 9: RAPPORT DE VÉRIFICATION
-- ============================================================================

DO $$
DECLARE
  active_count INTEGER;
  inactive_count INTEGER;
  mapping_count INTEGER;
  rec RECORD;
BEGIN
  SELECT COUNT(*) INTO active_count FROM service_types WHERE is_active = true;
  SELECT COUNT(*) INTO inactive_count FROM service_types WHERE is_active = false;
  SELECT COUNT(*) INTO mapping_count FROM service_type_code_mapping;
  
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE '📊 RAPPORT DE SYNCHRONISATION COMPLÈTE';
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE 'Services actifs: %', active_count;
  RAISE NOTICE 'Services désactivés: %', inactive_count;
  RAISE NOTICE 'Mappings de migration: %', mapping_count;
  RAISE NOTICE '════════════════════════════════════════════════════';
  
  RAISE NOTICE '';
  RAISE NOTICE '✅ SERVICES ACTIFS (synchronisés avec Auth.tsx):';
  FOR rec IN 
    SELECT code, name, category 
    FROM service_types 
    WHERE is_active = true 
    ORDER BY 
      CASE category
        WHEN 'Commerce' THEN 1
        WHEN 'Alimentation' THEN 2
        WHEN 'Beauté' THEN 3
        WHEN 'Transport' THEN 4
        WHEN 'Réparation' THEN 5
        WHEN 'Services' THEN 6
        WHEN 'Technologie' THEN 7
        WHEN 'Sport' THEN 8
        ELSE 99
      END,
      name
  LOOP
    RAISE NOTICE '  ✓ % (%) - %', rec.name, rec.code, rec.category;
  END LOOP;
  
  RAISE NOTICE '';
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE '✅ Migration terminée avec succès!';
END $$;

-- ============================================================================
-- CORRESPONDANCE COMPLÈTE Auth.tsx ↔ service_types
-- ============================================================================
/*
SERVICES DE PROXIMITÉ POPULAIRES (Auth.tsx):
✓ restaurant    → Restaurant / Alimentation
✓ beaute        → Beauté & Bien-être
✓ vtc           → VTC / Transport
✓ reparation    → Réparation / Mécanique
✓ menage        → Ménage & Entretien
✓ informatique  → Informatique / Tech

SERVICES PROFESSIONNELS (Auth.tsx):
✓ sport         → Sport & Fitness (NOUVEAU)
✓ location      → Location Immobilière
✓ media         → Photographe / Vidéaste
✓ construction  → Construction / BTP
✓ agriculture   → Agriculture
✓ freelance     → Services Professionnels
✓ sante         → Santé & Bien-être
✓ maison        → Maison & Déco (NOUVEAU)

PRODUITS NUMÉRIQUES (Auth.tsx):
✓ digital_logiciel → Logiciel / SaaS (NOUVEAU)
✓ dropshipping     → Dropshipping (NOUVEAU)
✓ education        → Éducation / Formation
✓ digital_livre    → Livres & eBooks (NOUVEAU)

BOUTON E-COMMERCE CLASSIQUE:
✓ ecommerce     → Boutique / E-commerce (mode par défaut)

AUTRES:
✓ livraison     → Livraison / Coursier
✓ voyage        → Voyage / Tourisme
*/
