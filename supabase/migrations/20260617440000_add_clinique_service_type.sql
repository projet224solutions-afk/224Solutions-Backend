-- ============================================================================
-- SERVICE_TYPE 'clinique' — sous-type du domaine « Santé & Bien-être ».
--
-- À l'inscription, « Santé & Bien-être » est une catégorie qui propose désormais
-- 3 sous-types : Pharmacie (existant), Clinique (NOUVEAU), Soins/Bien-être ('sante').
-- Cette migration ajoute le type 'clinique' (catégorie Santé) + un plan gratuit de
-- base (le PDG pourra ajouter des paliers payants ensuite, comme pour les autres
-- services). Idempotent — ne touche aucun service existant.
-- ============================================================================

-- 1) Type de service 'clinique' (catégorie Santé). Idempotent par code.
INSERT INTO public.service_types (id, code, name, description, icon, category, is_active, commission_rate, features)
SELECT 'c1f2e3d4-a5b6-47c8-9d0e-1f2a3b4c5d6e', 'clinique', 'Clinique',
       'Clinique : consultations, prises de rendez-vous, analyses et soins médicaux',
       'Building2', 'Santé', true, 10,
       to_jsonb(ARRAY['Consultations','Prise de rendez-vous','Analyses médicales','Suivi patient'])
WHERE NOT EXISTS (SELECT 1 FROM public.service_types WHERE code = 'clinique');

-- 2) Plan gratuit de base (idempotent par (service_type_id, name)).
INSERT INTO public.service_plans
  (service_type_id, name, display_name, description, monthly_price_gnf, yearly_price_gnf,
   commission_rate, max_bookings_per_month, max_products, priority_listing, analytics_access,
   can_upload_video, is_active, display_order, features)
SELECT st.id, 'free', 'Gratuit', 'Offre de base pour démarrer (configurable par le PDG)',
       0, 0, 15, 20, 30, false, false, false, true, 1,
       to_jsonb(ARRAY['20 rendez-vous/mois','Fiche clinique','Visible dans la recherche de proximité'])
FROM public.service_types st
WHERE st.code = 'clinique'
  AND NOT EXISTS (SELECT 1 FROM public.service_plans sp WHERE sp.service_type_id = st.id AND sp.name = 'free');

SELECT 'service_type clinique ajouté (catégorie Santé) + plan gratuit. Inscription : Santé & Bien-être → Pharmacie / Clinique / Soins.' AS status;
