-- ================================================================
-- MIGRATION : Abonnements gratuits pour les services actifs
-- À exécuter dans le Supabase Dashboard → SQL Editor
-- ================================================================
-- Crée un abonnement plan "free" pour tout service actif
-- qui n'a pas encore d'abonnement actif.
-- current_period_end = 1 an à partir d'aujourd'hui.
-- ================================================================

DO $$
DECLARE
  v_free_plan_id UUID;
  v_count INTEGER := 0;
BEGIN
  -- Récupérer l'ID du plan gratuit (sans filtre service_type_id pour avoir le plan générique)
  SELECT id INTO v_free_plan_id
  FROM public.service_plans
  WHERE name = 'free'
    AND service_type_id IS NULL
    AND is_active = true
  ORDER BY created_at ASC
  LIMIT 1;

  -- Si aucun plan free sans service_type_id, prendre le premier plan free disponible
  IF v_free_plan_id IS NULL THEN
    SELECT id INTO v_free_plan_id
    FROM public.service_plans
    WHERE name = 'free' AND is_active = true
    ORDER BY created_at ASC
    LIMIT 1;
  END IF;

  IF v_free_plan_id IS NULL THEN
    RAISE EXCEPTION 'Aucun plan "free" trouvé dans service_plans. Veuillez vérifier la table.';
  END IF;

  RAISE NOTICE 'Plan free trouvé : %', v_free_plan_id;

  -- Insérer un abonnement gratuit pour chaque service actif sans abonnement actif
  INSERT INTO public.service_subscriptions (
    professional_service_id,
    user_id,
    plan_id,
    status,
    billing_cycle,
    price_paid_gnf,
    payment_method,
    started_at,
    current_period_start,
    current_period_end,
    auto_renew,
    metadata
  )
  SELECT
    ps.id                         AS professional_service_id,
    ps.user_id                    AS user_id,
    v_free_plan_id                AS plan_id,
    'active'                      AS status,
    'yearly'                      AS billing_cycle,
    0                             AS price_paid_gnf,
    'admin'                       AS payment_method,
    now()                         AS started_at,
    now()                         AS current_period_start,
    now() + INTERVAL '1 year'     AS current_period_end,
    false                         AS auto_renew,
    '{"source": "migration_seed", "note": "Abonnement gratuit créé automatiquement pour les services existants"}'::jsonb AS metadata
  FROM public.professional_services ps
  WHERE ps.status = 'active'
    AND NOT EXISTS (
      SELECT 1
      FROM public.service_subscriptions ss
      WHERE ss.professional_service_id = ps.id
        AND ss.status = 'active'
        AND ss.current_period_end >= now()
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE '✅ % abonnement(s) gratuit(s) créé(s) avec succès.', v_count;

END $$;

-- Vérification : afficher les abonnements créés
SELECT
  ps.business_name,
  ps.status AS service_status,
  ss.status AS sub_status,
  ss.plan_id,
  sp.name AS plan_name,
  ss.current_period_end
FROM public.professional_services ps
JOIN public.service_subscriptions ss ON ss.professional_service_id = ps.id
JOIN public.service_plans sp ON sp.id = ss.plan_id
WHERE ss.status = 'active'
  AND ss.current_period_end >= now()
ORDER BY ps.business_name;
