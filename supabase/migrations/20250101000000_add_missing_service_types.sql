-- ============================================================================
-- AJOUT DES TYPES DE SERVICES MANQUANTS
-- Migration pour compléter la table service_types avec les nouveaux services
-- ============================================================================

-- Insertion des types de services manquants pour atteindre 100% de couverture
INSERT INTO public.service_types (code, name, description, icon, category, features, commission_rate) VALUES
-- VTC Service
('vtc', 'Transport VTC', 'Service de transport avec véhicule de tourisme avec chauffeur', '🚗', 'transport', '["Réservation instantanée", "Suivi GPS temps réel", "Tarification dynamique", "Historique complet", "Chat chauffeur"]'::jsonb, 15.00),

-- Mode & Fashion
('mode', 'Mode & Vêtements', 'E-commerce mode avec tailles et couleurs', '👗', 'commerce', '["Gestion variantes", "Tailles/Couleurs", "Stock détaillé", "Promotions", "Livraison gratuite"]'::jsonb, 8.00),

-- Électronique
('electronique', 'Électronique & High-Tech', 'Vente de produits électroniques et informatiques', '💻', 'commerce', '["Fiches techniques", "Garantie", "Support client", "Comparaison produits"]'::jsonb, 7.00),

-- Décoration maison
('maison', 'Maison & Décoration', 'Mobilier et décoration intérieure', '🛋️', 'commerce', '["Catalogue 3D", "Conseils déco", "Livraison/Installation", "Personnalisation"]'::jsonb, 8.00),

-- Dropshipping
('dropshipping', 'Dropshipping', 'Vente sans stock avec fournisseurs intégrés', '📦', 'commerce', '["Import produits", "Multi-fournisseurs", "Calcul marge auto", "Synchronisation stock"]'::jsonb, 5.00),

-- Sport & Fitness  
('sport', 'Sport & Fitness', 'Coaching sportif et salles de sport', '💪', 'services', '["Planning cours", "Réservations", "Suivi progrès", "Coaching personnel"]'::jsonb, 12.00)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  icon = EXCLUDED.icon,
  category = EXCLUDED.category,
  features = EXCLUDED.features,
  commission_rate = EXCLUDED.commission_rate,
  updated_at = now();

-- Vérification des données insérées
DO $$
DECLARE
  service_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO service_count FROM public.service_types WHERE is_active = true;
  RAISE NOTICE 'Total service types actifs: %', service_count;
END $$;
