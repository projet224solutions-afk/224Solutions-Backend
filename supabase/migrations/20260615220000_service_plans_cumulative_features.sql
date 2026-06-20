-- ============================================================================
-- PHASE 1 (correctif) — FONCTIONNALITÉS CUMULATIVES PAR PALIER
-- ----------------------------------------------------------------------------
-- Les booléens (analytics/priority/sms/branding) étaient dérivés du texte de CHAQUE
-- palier isolément → un palier supérieur PERDAIT une fonctionnalité que l'inférieur
-- avait (ex. premium analytics=false alors que pro=true). Un abonnement est cumulatif :
-- chaque palier inclut tout ce que les paliers inférieurs offrent. On recalcule donc
-- chaque booléen par bool_or sur tous les paliers de display_order <= courant.
-- Gère aussi les négations (« Sans rappels … » ne doit PAS activer sms). Idempotent.
-- ============================================================================

WITH ranked AS (
  SELECT sp.id, sp.service_type_id, sp.display_order,
    (sp.features::text ILIKE '%Analytics%')                                   AS a,
    (sp.features::text ILIKE '%Priorité%'
      OR sp.features::text ILIKE '%Mise en avant%'
      OR sp.features::text ILIKE '%Tête %')                                   AS p,
    ((sp.features::text ILIKE '%SMS%' OR sp.features::text ILIKE '%Rappels%')
      AND sp.features::text NOT ILIKE '%Sans rappels%')                       AS s,
    (sp.features::text ILIKE '%Badge%')                                       AS b
  FROM public.service_plans sp
  JOIN public.service_types st ON st.id = sp.service_type_id
  WHERE st.code IN ('agriculture','restaurant','beaute','ecommerce','construction',
                    'education','location','maison','media','freelance','reparation')
),
cum AS (
  SELECT id,
    bool_or(a) OVER w AS analytics,
    bool_or(p) OVER w AS priority,
    bool_or(s) OVER w AS sms,
    bool_or(b) OVER w AS branding
  FROM ranked
  WINDOW w AS (PARTITION BY service_type_id ORDER BY display_order
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
)
UPDATE public.service_plans sp
SET analytics_access  = cum.analytics,
    priority_listing  = cum.priority,
    sms_notifications = cum.sms,
    custom_branding   = cum.branding,
    updated_at        = now()
FROM cum
WHERE cum.id = sp.id;

-- ── Vérification finale : répartition cumulative attendue ────────────────────
SELECT st.code AS service, sp.name AS plan, sp.monthly_price_gnf AS prix,
       sp.max_products, sp.max_bookings_per_month AS max_cmd_mois,
       sp.analytics_access AS analytics, sp.priority_listing AS mise_avant,
       sp.sms_notifications AS sms, sp.commission_rate AS commission
FROM public.service_plans sp
JOIN public.service_types st ON st.id = sp.service_type_id
WHERE st.code IN ('agriculture','restaurant','beaute','ecommerce','construction',
                  'education','location','maison','media','freelance','reparation')
ORDER BY st.code, sp.display_order;
