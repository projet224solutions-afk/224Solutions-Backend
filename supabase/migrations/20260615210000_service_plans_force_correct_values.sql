-- ============================================================================
-- PHASE 1 (CORRECTIF CRITIQUE) — FORCER les valeurs par métier dans service_plans
-- ----------------------------------------------------------------------------
-- Le seed 20260615100000 finissait par ON CONFLICT DO NOTHING : des plans GÉNÉRIQUES
-- existaient déjà pour (service_type_id, name) → mes valeurs par métier n'ont JAMAIS
-- été écrites (DB uniforme 2/15/50, commission null). Ici : UPSERT (DO UPDATE) qui
-- écrit réellement prix / commission_rate / max_products / features par métier, PUIS
-- resync des colonnes appliquées depuis le texte features. Même plan_id conservé ⇒
-- les abonnements existants restent valides. Idempotent.
-- ============================================================================

INSERT INTO public.service_plans
  (service_type_id, name, display_name, description, monthly_price_gnf, commission_rate, max_products, features, display_order, is_active)
SELECT st.id, v.name, v.display_name, v.description, v.price, v.commission, v.max_products, v.features::jsonb, v.display_order, true
FROM (VALUES
  ('agriculture','free','Gratuit','Pour démarrer',0,NULL,5,'["5 produits","10 commandes/mois","Sans QR traçabilité"]',0),
  ('agriculture','basic','Basic','Petite exploitation',5000,NULL,20,'["20 produits","50 commandes/mois","QR traçabilité"]',1),
  ('agriculture','pro','Pro','En croissance',15000,NULL,999999,'["Produits illimités","Carte des parcelles","Analytics ventes","Acheteurs professionnels"]',2),
  ('agriculture','premium','Premium','Leader',30000,NULL,999999,'["Badge Certifié","Export comptable PDF","Priorité recherche"]',3),
  ('restaurant','free','Gratuit','Pour démarrer',0,15.00,10,'["10 plats","Sans promotions"]',0),
  ('restaurant','basic','Basic','Petit resto',10000,12.00,30,'["30 plats","1 promotion active"]',1),
  ('restaurant','pro','Pro','En croissance',25000,8.00,999999,'["Plats illimités","Promotions illimitées","Analytics complet","Badge Recommandé"]',2),
  ('restaurant','premium','Premium','Leader',50000,5.00,999999,'["Tête des résultats","Livraison prioritaire","1 campagne marketing/mois"]',3),
  ('beaute','free','Gratuit','Pour démarrer',0,NULL,3,'["3 services","Agenda basique","Sans rappels auto"]',0),
  ('beaute','basic','Basic','Salon solo',8000,NULL,10,'["10 services","Rappels SMS 50/mois","Galerie 20 photos","CRM basique"]',1),
  ('beaute','pro','Pro','Salon établi',20000,NULL,999999,'["Services illimités","Rappels illimités","CRM complet","Gestion no-show","Fidélité","Analytics","Scheduling IA"]',2),
  ('beaute','premium','Premium','Référence',40000,NULL,999999,'["Badge Certifié","Vente de produits","Mise en avant"]',3),
  ('ecommerce','free','Gratuit','Pour démarrer',0,10.00,10,'["10 produits","Sans flash sales"]',0),
  ('ecommerce','basic','Basic','Petite boutique',12000,8.00,50,'["50 produits"]',1),
  ('ecommerce','pro','Pro','En croissance',25000,5.00,200,'["200 produits","Flash sales illimitées","Achat groupé","Analytics avancé"]',2),
  ('ecommerce','premium','Premium','Leader',50000,3.00,999999,'["Produits illimités","Tête de page d''accueil","Badge Boutique certifiée"]',3),
  ('construction','free','Gratuit','Pour démarrer',0,NULL,2,'["2 projets actifs","Sans PDF devis"]',0),
  ('construction','basic','Basic','Artisan',15000,NULL,5,'["5 projets","Devis PDF","Journal de chantier","5 photos/rapport"]',1),
  ('construction','pro','Pro','Entreprise',35000,NULL,20,'["20 projets","Photos illimitées","Budget tracker","Jalons escrow","Sous-traitants","Badge vérifié","Analytics"]',2),
  ('construction','premium','Premium','Grand compte',70000,NULL,999999,'["Projets illimités","Analyse photos IA","Export comptable","Appels d''offres entreprises"]',3),
  ('education','free','Gratuit','Pour démarrer',0,30.00,1,'["1 cours","10 étudiants max"]',0),
  ('education','basic','Basic','Formateur',10000,20.00,3,'["3 cours","50 étudiants"]',1),
  ('education','pro','Pro','Établi',25000,12.00,10,'["10 cours","Étudiants illimités","Sessions live","Certificats","Quiz","Analytics"]',2),
  ('education','premium','Premium','Expert',50000,8.00,999999,'["Cours illimités","Badge Expert","Parcours multi-cours","Téléchargement contenus"]',3),
  ('location','free','Gratuit','Pour démarrer',0,NULL,1,'["1 bien","5 photos","Sans contrat digital"]',0),
  ('location','basic','Basic','Petit bailleur',10000,NULL,3,'["3 biens","10 photos","Contrat PDF"]',1),
  ('location','pro','Pro','Multi-biens',25000,NULL,10,'["10 biens","Photos illimitées","Contrat signé","Quittances auto","Escrow caution","Analytics"]',2),
  ('location','premium','Premium','Pro immobilier',50000,NULL,999999,'["Biens illimités","Badge vérifié","Tarification dynamique"]',3),
  ('maison','free','Gratuit','Pour démarrer',0,NULL,3,'["Offre découverte"]',0),
  ('maison','basic','Basic','Artisan déco',8000,NULL,20,'["Devis PDF","Galerie réalisations"]',1),
  ('maison','pro','Pro','Établi',20000,NULL,999999,'["Illimité","Agenda interventions","Analytics"]',2),
  ('maison','premium','Premium','Référence',40000,NULL,999999,'["Badge certifié","Mise en avant"]',3),
  ('media','free','Gratuit','Pour démarrer',0,NULL,3,'["Offre découverte"]',0),
  ('media','basic','Basic','Photographe',8000,NULL,20,'["Packages","Galerie privée client"]',1),
  ('media','pro','Pro','Studio',20000,NULL,999999,'["Illimité","Retouche","Livraison HD sécurisée"]',2),
  ('media','premium','Premium','Référence',40000,NULL,999999,'["Badge certifié","Mise en avant"]',3),
  ('freelance','free','Gratuit','Pour démarrer',0,NULL,3,'["Gigs basiques"]',0),
  ('freelance','basic','Basic','Indépendant',8000,NULL,20,'["Gigs 3 niveaux","Portfolio"]',1),
  ('freelance','pro','Pro','Pro établi',20000,NULL,999999,'["Illimité","Suivi du temps","Contrats digitaux"]',2),
  ('freelance','premium','Premium','Expert',40000,NULL,999999,'["Badge certifié","Mise en avant"]',3),
  ('reparation','free','Gratuit','Pour démarrer',0,NULL,5,'["5 interventions/mois","Sans urgences"]',0),
  ('reparation','basic','Basic','Mécano',10000,NULL,20,'["20 interventions","Urgences","Suivi Uber","Photos intervention"]',1),
  ('reparation','pro','Pro','Garage',25000,NULL,999999,'["Illimité","Fiches véhicules","Analytics","Badge certifié"]',2),
  ('reparation','premium','Premium','Réseau',50000,NULL,999999,'["Badge urgentiste 24h/7j","Priorité résultats","Contrats entreprises"]',3)
) AS v(code,name,display_name,description,price,commission,max_products,features,display_order)
JOIN public.service_types st ON st.code = v.code
ON CONFLICT (service_type_id, name) DO UPDATE SET
  display_name      = EXCLUDED.display_name,
  description       = EXCLUDED.description,
  monthly_price_gnf = EXCLUDED.monthly_price_gnf,
  commission_rate   = EXCLUDED.commission_rate,
  max_products      = EXCLUDED.max_products,
  features          = EXCLUDED.features,
  display_order     = EXCLUDED.display_order,
  is_active         = true,
  updated_at        = now();

-- ── Resync des colonnes APPLIQUÉES depuis le texte features (sur les 11 métiers ci-dessus) ──
WITH seeded AS (
  SELECT st.id AS service_type_id
  FROM public.service_types st
  WHERE st.code IN ('agriculture','restaurant','beaute','ecommerce','construction',
                    'education','location','maison','media','freelance','reparation')
)
UPDATE public.service_plans sp
SET
  analytics_access  = (sp.features::text ILIKE '%Analytics%'),
  priority_listing  = (sp.features::text ILIKE '%Priorité%' OR sp.features::text ILIKE '%Mise en avant%' OR sp.features::text ILIKE '%Tête %'),
  sms_notifications = (sp.features::text ILIKE '%SMS%' OR sp.features::text ILIKE '%Rappels%'),
  custom_branding   = (sp.features::text ILIKE '%Badge%'),
  updated_at        = now()
FROM seeded WHERE sp.service_type_id = seeded.service_type_id;

-- ── Plafonds de transactions/mois explicitement promis ──────────────────────
-- Remet illimité (NULL) partout sur les 11 métiers, puis fixe les caps annoncés.
WITH seeded AS (
  SELECT st.id AS service_type_id, st.code
  FROM public.service_types st
  WHERE st.code IN ('agriculture','restaurant','beaute','ecommerce','construction',
                    'education','location','maison','media','freelance','reparation')
)
UPDATE public.service_plans sp SET max_bookings_per_month = NULL
FROM seeded WHERE sp.service_type_id = seeded.service_type_id;

UPDATE public.service_plans sp
SET max_bookings_per_month = m.cap, updated_at = now()
FROM (VALUES
  ('agriculture','free',10),('agriculture','basic',50),
  ('reparation','free',5),  ('reparation','basic',20)
) AS m(code, plan_name, cap)
JOIN public.service_types st ON st.code = m.code
WHERE sp.service_type_id = st.id AND sp.name = m.plan_name;

-- ── Vérification : valeurs RÉELLEMENT appliquées (11 métiers) ────────────────
SELECT st.code AS service, sp.name AS plan, sp.monthly_price_gnf AS prix,
       sp.max_products, sp.max_bookings_per_month AS max_cmd_mois,
       sp.analytics_access AS analytics, sp.priority_listing AS mise_avant,
       sp.sms_notifications AS sms, sp.commission_rate AS commission
FROM public.service_plans sp
JOIN public.service_types st ON st.id = sp.service_type_id
WHERE st.code IN ('agriculture','restaurant','beaute','ecommerce','construction',
                  'education','location','maison','media','freelance','reparation')
ORDER BY st.code, sp.display_order;
