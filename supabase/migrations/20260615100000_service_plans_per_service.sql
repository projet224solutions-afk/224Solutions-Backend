-- ============================================================================
-- PHASE 1 — ABONNEMENTS PAR SERVICE (prix/limites/commissions du cahier des charges)
-- ----------------------------------------------------------------------------
-- Ajoute commission_rate à service_plans + seed des 4 tiers (free/basic/pro/premium)
-- SPÉCIFIQUES à chaque métier. Le front préfère ces plans typés aux génériques.
-- Rejouable (ON CONFLICT). max_products = 999999 ⇒ illimité.
-- ============================================================================

ALTER TABLE public.service_plans ADD COLUMN IF NOT EXISTS commission_rate numeric(5,2);

-- Unicité (service_type_id, name) pour rejouabilité du seed.
CREATE UNIQUE INDEX IF NOT EXISTS uq_service_plans_type_name ON public.service_plans (service_type_id, name);

INSERT INTO public.service_plans
  (service_type_id, name, display_name, description, monthly_price_gnf, commission_rate, max_products, features, display_order, is_active)
SELECT st.id, v.name, v.display_name, v.description, v.price, v.commission, v.max_products, v.features::jsonb, v.display_order, true
FROM (VALUES
  -- ── AGRICULTURE ───────────────────────────────────────────────────────────
  ('agriculture','free','Gratuit','Pour démarrer',0,NULL,5,'["5 produits","10 commandes/mois","Sans QR traçabilité"]',0),
  ('agriculture','basic','Basic','Petite exploitation',5000,NULL,20,'["20 produits","50 commandes/mois","QR traçabilité"]',1),
  ('agriculture','pro','Pro','En croissance',15000,NULL,999999,'["Produits illimités","Carte des parcelles","Analytics ventes","Acheteurs professionnels"]',2),
  ('agriculture','premium','Premium','Leader',30000,NULL,999999,'["Badge Certifié","Export comptable PDF","Priorité recherche"]',3),
  -- ── RESTAURANT (commission dégressive) ───────────────────────────────────
  ('restaurant','free','Gratuit','Pour démarrer',0,15.00,10,'["10 plats","Sans promotions"]',0),
  ('restaurant','basic','Basic','Petit resto',10000,12.00,30,'["30 plats","1 promotion active"]',1),
  ('restaurant','pro','Pro','En croissance',25000,8.00,999999,'["Plats illimités","Promotions illimitées","Analytics complet","Badge Recommandé"]',2),
  ('restaurant','premium','Premium','Leader',50000,5.00,999999,'["Tête des résultats","Livraison prioritaire","1 campagne marketing/mois"]',3),
  -- ── BEAUTÉ (0% commission, modèle Fresha) ────────────────────────────────
  ('beaute','free','Gratuit','Pour démarrer',0,NULL,3,'["3 services","Agenda basique","Sans rappels auto"]',0),
  ('beaute','basic','Basic','Salon solo',8000,NULL,10,'["10 services","Rappels SMS 50/mois","Galerie 20 photos","CRM basique"]',1),
  ('beaute','pro','Pro','Salon établi',20000,NULL,999999,'["Services illimités","Rappels illimités","CRM complet","Gestion no-show","Fidélité","Analytics","Scheduling IA"]',2),
  ('beaute','premium','Premium','Référence',40000,NULL,999999,'["Badge Certifié","Vente de produits","Mise en avant"]',3),
  -- ── E-COMMERCE (commission dégressive) ───────────────────────────────────
  ('ecommerce','free','Gratuit','Pour démarrer',0,10.00,10,'["10 produits","Sans flash sales"]',0),
  ('ecommerce','basic','Basic','Petite boutique',12000,8.00,50,'["50 produits"]',1),
  ('ecommerce','pro','Pro','En croissance',25000,5.00,200,'["200 produits","Flash sales illimitées","Achat groupé","Analytics avancé"]',2),
  ('ecommerce','premium','Premium','Leader',50000,3.00,999999,'["Produits illimités","Tête de page d''accueil","Badge Boutique certifiée"]',3),
  -- ── CONSTRUCTION / BTP (escrow par jalon) ────────────────────────────────
  ('construction','free','Gratuit','Pour démarrer',0,NULL,2,'["2 projets actifs","Sans PDF devis"]',0),
  ('construction','basic','Basic','Artisan',15000,NULL,5,'["5 projets","Devis PDF","Journal de chantier","5 photos/rapport"]',1),
  ('construction','pro','Pro','Entreprise',35000,NULL,20,'["20 projets","Photos illimitées","Budget tracker","Jalons escrow","Sous-traitants","Badge vérifié","Analytics"]',2),
  ('construction','premium','Premium','Grand compte',70000,NULL,999999,'["Projets illimités","Analyse photos IA","Export comptable","Appels d''offres entreprises"]',3),
  -- ── ÉDUCATION (commission dégressive) ────────────────────────────────────
  ('education','free','Gratuit','Pour démarrer',0,30.00,1,'["1 cours","10 étudiants max"]',0),
  ('education','basic','Basic','Formateur',10000,20.00,3,'["3 cours","50 étudiants"]',1),
  ('education','pro','Pro','Établi',25000,12.00,10,'["10 cours","Étudiants illimités","Sessions live","Certificats","Quiz","Analytics"]',2),
  ('education','premium','Premium','Expert',50000,8.00,999999,'["Cours illimités","Badge Expert","Parcours multi-cours","Téléchargement contenus"]',3),
  -- ── IMMOBILIER (location) ────────────────────────────────────────────────
  ('location','free','Gratuit','Pour démarrer',0,NULL,1,'["1 bien","5 photos","Sans contrat digital"]',0),
  ('location','basic','Basic','Petit bailleur',10000,NULL,3,'["3 biens","10 photos","Contrat PDF"]',1),
  ('location','pro','Pro','Multi-biens',25000,NULL,10,'["10 biens","Photos illimitées","Contrat signé","Quittances auto","Escrow caution","Analytics"]',2),
  ('location','premium','Premium','Pro immobilier',50000,NULL,999999,'["Biens illimités","Badge vérifié","Tarification dynamique"]',3),
  -- ── MAISON & DÉCO ────────────────────────────────────────────────────────
  ('maison','free','Gratuit','Pour démarrer',0,NULL,3,'["Offre découverte"]',0),
  ('maison','basic','Basic','Artisan déco',8000,NULL,20,'["Devis PDF","Galerie réalisations"]',1),
  ('maison','pro','Pro','Établi',20000,NULL,999999,'["Illimité","Agenda interventions","Analytics"]',2),
  ('maison','premium','Premium','Référence',40000,NULL,999999,'["Badge certifié","Mise en avant"]',3),
  -- ── PHOTO / VIDÉO (media) ────────────────────────────────────────────────
  ('media','free','Gratuit','Pour démarrer',0,NULL,3,'["Offre découverte"]',0),
  ('media','basic','Basic','Photographe',8000,NULL,20,'["Packages","Galerie privée client"]',1),
  ('media','pro','Pro','Studio',20000,NULL,999999,'["Illimité","Retouche","Livraison HD sécurisée"]',2),
  ('media','premium','Premium','Référence',40000,NULL,999999,'["Badge certifié","Mise en avant"]',3),
  -- ── SERVICES PRO / FREELANCE (escrow) ────────────────────────────────────
  ('freelance','free','Gratuit','Pour démarrer',0,NULL,3,'["Gigs basiques"]',0),
  ('freelance','basic','Basic','Indépendant',8000,NULL,20,'["Gigs 3 niveaux","Portfolio"]',1),
  ('freelance','pro','Pro','Pro établi',20000,NULL,999999,'["Illimité","Suivi du temps","Contrats digitaux"]',2),
  ('freelance','premium','Premium','Expert',40000,NULL,999999,'["Badge certifié","Mise en avant"]',3),
  -- ── RÉPARATION / MÉCANIQUE ───────────────────────────────────────────────
  ('reparation','free','Gratuit','Pour démarrer',0,NULL,5,'["5 interventions/mois","Sans urgences"]',0),
  ('reparation','basic','Basic','Mécano',10000,NULL,20,'["20 interventions","Urgences","Suivi Uber","Photos intervention"]',1),
  ('reparation','pro','Pro','Garage',25000,NULL,999999,'["Illimité","Fiches véhicules","Analytics","Badge certifié"]',2),
  ('reparation','premium','Premium','Réseau',50000,NULL,999999,'["Badge urgentiste 24h/7j","Priorité résultats","Contrats entreprises"]',3)
) AS v(code,name,display_name,description,price,commission,max_products,features,display_order)
JOIN public.service_types st ON st.code = v.code
ON CONFLICT (service_type_id, name) DO NOTHING;

SELECT 'Plans par service seedés (' || count(*) || ' lignes typées).' AS status
FROM public.service_plans WHERE service_type_id IS NOT NULL;
