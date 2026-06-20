-- ============================================================================
-- PHASE 1 (correctif) — SYNCHRONISER les colonnes APPLIQUÉES avec le texte `features`
-- ----------------------------------------------------------------------------
-- Constat : le seed 20260615100000 a rempli prix / commission_rate / max_products /
-- features(texte), MAIS pas les colonnes structurées que le code applique réellement
-- (get_service_subscription → useServiceLimits) : analytics_access, priority_listing,
-- max_bookings_per_month, sms_notifications. Les fonctionnalités étaient donc DÉCRITES
-- mais inertes. Ce correctif les reporte depuis le texte `features`, par mot-clé.
-- Idempotent (réexécutable). Ne touche que les plans TYPÉS (service_type_id NOT NULL).
-- ============================================================================

UPDATE public.service_plans sp
SET
  -- Analytics : tout plan dont les features mentionnent « Analytics »
  analytics_access = (sp.features::text ILIKE '%Analytics%'),

  -- Mise en avant / ranking : « Priorité », « Mise en avant », « Tête … » (résultats / page d'accueil)
  priority_listing = (
       sp.features::text ILIKE '%Priorité%'
    OR sp.features::text ILIKE '%Mise en avant%'
    OR sp.features::text ILIKE '%Tête %'
  ),

  -- Notifications SMS : plans qui promettent des rappels / SMS
  sms_notifications = (
       sp.features::text ILIKE '%SMS%'
    OR sp.features::text ILIKE '%Rappels%'
  ),

  -- Branding / badge : plans qui annoncent un badge certifié / vérifié / expert
  custom_branding = (
       sp.features::text ILIKE '%Badge%'
  ),

  updated_at = now()
WHERE sp.service_type_id IS NOT NULL;

-- ── Plafonds de transactions/mois explicitement annoncés ("X commandes/mois",
--    "X interventions/mois"). NULL = illimité. On ne plafonne que là où c'est promis.
UPDATE public.service_plans sp
SET max_bookings_per_month = m.cap, updated_at = now()
FROM (VALUES
  ('agriculture','free',10),
  ('agriculture','basic',50),
  ('reparation','free',5),
  ('reparation','basic',20)
) AS m(code, plan_name, cap)
JOIN public.service_types st ON st.code = m.code
WHERE sp.service_type_id = st.id AND sp.name = m.plan_name;

-- ── Vérification : ce que le code va RÉELLEMENT appliquer, par plan ──────────
SELECT st.code AS service, sp.name AS plan,
       sp.max_products, sp.max_bookings_per_month AS max_cmd_mois,
       sp.analytics_access AS analytics, sp.priority_listing AS mise_avant,
       sp.sms_notifications AS sms, sp.commission_rate AS commission
FROM public.service_plans sp
JOIN public.service_types st ON st.id = sp.service_type_id
ORDER BY st.code, sp.display_order;
