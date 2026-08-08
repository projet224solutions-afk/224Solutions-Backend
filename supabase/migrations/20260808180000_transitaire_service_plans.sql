-- ============================================================================
-- 💳 GRILLE D'ABONNEMENT DU TRANSITAIRE
-- ----------------------------------------------------------------------------
-- POURQUOI CE FICHIER EST NÉCESSAIRE (constaté en base, 08/08/2026) : le sélecteur
-- de plans retombe sur les plans GLOBAUX (`service_type_id IS NULL`) quand un métier
-- n'a pas sa grille — mais il n'existe AUCUN plan global actif. Sans grille propre,
-- le transitaire verrait « aucun plan », ne pourrait donc jamais s'abonner, et resterait
-- invisible en proximité (la règle « pas d'abonnement → pas de visibilité » s'applique
-- à lui comme aux autres). Le pont de la migration précédente serait resté lettre morte.
--
-- ⚠️ PRIX = DÉCISION PDG, NON PRISE ICI. Ces montants sont une RECOPIE EXACTE de la
-- grille « Informatique / Tech », choisie comme palier « service professionnel standard »
-- déjà en vigueur sur la plateforme (25 000 / 75 000 / 150 000 GNF par mois, mêmes prix
-- annuels). Aucun chiffre n'a été inventé. Le PDG ajuste ces montants depuis sa console
-- (service_plans est éditable, avec historique dans service_plan_price_history) — ce
-- fichier ne fait que garantir que le transitaire N'EST PAS BLOQUÉ en attendant.
--
-- Idempotent : ON CONFLICT sur (service_type_id, name) via l'index unique créé ici.
-- Ne touche à aucune grille existante.
-- ============================================================================

-- Index d'idempotence (sans lui, un re-run dupliquerait les plans).
CREATE UNIQUE INDEX IF NOT EXISTS uq_service_plans_type_name
  ON public.service_plans (service_type_id, name);

INSERT INTO public.service_plans (
  service_type_id, name, display_name, description,
  monthly_price_gnf, yearly_price_gnf, yearly_discount_percentage,
  max_bookings_per_month, max_products, max_staff,
  priority_listing, analytics_access, sms_notifications, email_notifications,
  custom_branding, api_access, can_upload_video, display_order, is_active
)
SELECT
  st.id, v.name, v.display_name, v.description,
  v.monthly, v.yearly, v.remise,
  v.max_bookings, v.max_products, v.max_staff,
  v.prio, v.analytics, v.sms, v.email, v.branding, v.api, v.video, v.ordre, true
FROM public.service_types st
CROSS JOIN (VALUES
  ('free',    'Gratuit - Transitaire',      'Découverte : fiche visible, prestations limitées.',                    0::numeric,      0::numeric, 0,   10,  5,  1, false, false, false, true,  false, false, false, 0),
  ('basic',   'Basic - Transitaire',        'Activité régulière : catalogue complet et notifications.',        25000::numeric, 255000::numeric, 15,  50, 30,  3, false, true,  true,  true,  false, false, false, 1),
  ('pro',     'Professionnel - Transitaire','Volume : mise en avant, statistiques et équipe élargie.',          75000::numeric, 765000::numeric, 15, 500, 200, 10, true,  true,  true,  true,  true,  false, true,  2),
  ('premium', 'Premium - Transitaire',      'Sans limite : API, image de marque et priorité maximale.',        150000::numeric,1530000::numeric, 15,   0,   0,  0, true,  true,  true,  true,  true,  true,  true,  3)
) AS v(name, display_name, description, monthly, yearly, remise,
       max_bookings, max_products, max_staff, prio, analytics, sms, email, branding, api, video, ordre)
WHERE st.code = 'transitaire'
ON CONFLICT (service_type_id, name) DO NOTHING;

SELECT 'Grille transitaire posée (recopie du palier Informatique/Tech) — PRIX À VALIDER PAR LE PDG.' AS status;
