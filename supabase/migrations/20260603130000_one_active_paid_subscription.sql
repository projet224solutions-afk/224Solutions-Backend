-- =====================================================================
-- DURCISSEMENT : au plus UN abonnement PAYANT actif (anti double-facturation
-- par concurrence / double-clic simultané avec clés d'idempotence différentes)
-- =====================================================================
-- Index uniques PARTIELS :
--   - subscriptions          : 1 payant actif par user (le plan gratuit price=0 reste autorisé)
--   - service_subscriptions  : 1 payant actif par service (professional_service_id)
--   - driver_subscriptions   : 1 actif par user (pas de palier gratuit côté livreur/taxi)
--
-- Compatible avec les endpoints backend (insert d'UN seul abonnement payant à la
-- fois ; le free price=0 est exclu du filtre). Une 2e insertion concurrente est
-- rejetée par l'index → l'endpoint rembourse alors le wallet.
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

-- 0. Nettoyage défensif : ne garder que l'abonnement payant actif le plus récent
WITH ranked AS (
  SELECT id, row_number() OVER (
    PARTITION BY user_id
    ORDER BY current_period_end DESC NULLS LAST, created_at DESC
  ) AS rn
  FROM public.subscriptions
  WHERE status = 'active' AND price_paid_gnf > 0
)
UPDATE public.subscriptions s
SET status = 'expired', updated_at = now()
FROM ranked r
WHERE s.id = r.id AND r.rn > 1;

WITH ranked AS (
  SELECT id, row_number() OVER (
    PARTITION BY professional_service_id
    ORDER BY current_period_end DESC NULLS LAST, created_at DESC
  ) AS rn
  FROM public.service_subscriptions
  WHERE status = 'active' AND price_paid_gnf > 0
)
UPDATE public.service_subscriptions s
SET status = 'expired', updated_at = now()
FROM ranked r
WHERE s.id = r.id AND r.rn > 1;

WITH ranked AS (
  SELECT id, row_number() OVER (
    PARTITION BY user_id
    ORDER BY end_date DESC NULLS LAST, created_at DESC
  ) AS rn
  FROM public.driver_subscriptions
  WHERE status = 'active'
)
UPDATE public.driver_subscriptions s
SET status = 'expired', updated_at = now()
FROM ranked r
WHERE s.id = r.id AND r.rn > 1;

-- 1. Index uniques partiels
CREATE UNIQUE INDEX IF NOT EXISTS idx_subscriptions_one_active_paid
  ON public.subscriptions (user_id)
  WHERE status = 'active' AND price_paid_gnf > 0;

CREATE UNIQUE INDEX IF NOT EXISTS idx_service_subs_one_active_paid
  ON public.service_subscriptions (professional_service_id)
  WHERE status = 'active' AND price_paid_gnf > 0;

CREATE UNIQUE INDEX IF NOT EXISTS idx_driver_subs_one_active
  ON public.driver_subscriptions (user_id)
  WHERE status = 'active';
