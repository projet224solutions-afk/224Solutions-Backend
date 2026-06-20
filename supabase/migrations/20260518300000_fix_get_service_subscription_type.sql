-- ================================================================
-- FIX get_service_subscription — type mismatch price_paid (2026-05-18)
--
-- Problème critique :
--   service_subscriptions.price_paid_gnf est de type INTEGER
--   mais la fonction déclare price_paid NUMERIC dans RETURNS TABLE.
--   PostgreSQL ne fait PAS de cast implicite INTEGER→NUMERIC dans
--   RETURN QUERY → erreur "Returned type integer does not match
--   expected type numeric" → RPC échoue à chaque appel.
--
-- Conséquence :
--   Le hook useServiceSubscription reçoit une erreur → setSubscription(null)
--   → l'UI affiche "Gratuit" même après un paiement réussi → l'utilisateur
--   pense que la souscription a échoué → re-souscrit → annule la précédente.
--   Cela explique tous les abonnements payants annulés dans la DB.
--
-- Fix :
--   Ajouter le cast explicite ss.price_paid_gnf::NUMERIC dans le SELECT.
-- ================================================================

DROP FUNCTION IF EXISTS public.get_service_subscription(UUID);

CREATE OR REPLACE FUNCTION public.get_service_subscription(p_service_id UUID)
RETURNS TABLE(
  subscription_id    UUID,
  plan_id            UUID,
  plan_name          TEXT,
  plan_display_name  TEXT,
  status             TEXT,
  current_period_end TIMESTAMPTZ,
  auto_renew         BOOLEAN,
  price_paid         NUMERIC,
  max_bookings       INTEGER,
  max_products       INTEGER,
  max_staff          INTEGER,
  priority_listing   BOOLEAN,
  analytics_access   BOOLEAN,
  can_upload_video   BOOLEAN,
  features           JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Abonnement actif trouvé → retourner ses détails
  RETURN QUERY
  SELECT
    ss.id                              AS subscription_id,
    sp.id                              AS plan_id,
    sp.name::TEXT                      AS plan_name,
    sp.display_name::TEXT              AS plan_display_name,
    ss.status::TEXT,
    ss.current_period_end,
    ss.auto_renew,
    ss.price_paid_gnf::NUMERIC         AS price_paid,   -- FIX: cast explicite INTEGER→NUMERIC
    sp.max_bookings_per_month          AS max_bookings,
    sp.max_products,
    sp.max_staff,
    sp.priority_listing,
    sp.analytics_access,
    COALESCE(sp.can_upload_video, false) AS can_upload_video,
    sp.features
  FROM public.service_subscriptions ss
  JOIN public.service_plans sp ON sp.id = ss.plan_id
  WHERE ss.professional_service_id = p_service_id
    AND ss.status = 'active'
    AND ss.current_period_end > now()
  ORDER BY ss.created_at DESC
  LIMIT 1;

  -- Aucun abonnement actif → plan gratuit lié au type de service
  IF NOT FOUND THEN
    RETURN QUERY
    SELECT
      NULL::UUID                          AS subscription_id,
      sp.id                               AS plan_id,
      sp.name::TEXT                       AS plan_name,
      sp.display_name::TEXT               AS plan_display_name,
      'free'::TEXT                        AS status,
      NULL::TIMESTAMPTZ                   AS current_period_end,
      false                               AS auto_renew,
      0::NUMERIC                          AS price_paid,
      sp.max_bookings_per_month           AS max_bookings,
      sp.max_products,
      sp.max_staff,
      sp.priority_listing,
      sp.analytics_access,
      false                               AS can_upload_video,
      sp.features
    FROM public.service_plans sp
    JOIN public.professional_services ps ON ps.service_type_id = sp.service_type_id
    WHERE sp.name = 'free'
      AND ps.id = p_service_id
      AND sp.is_active = true
    LIMIT 1;
  END IF;

  -- Fallback ultime si aucun plan gratuit trouvé pour ce type de service
  IF NOT FOUND THEN
    RETURN QUERY
    SELECT
      NULL::UUID,
      NULL::UUID,
      'free'::TEXT,
      'Gratuit'::TEXT,
      'free'::TEXT,
      NULL::TIMESTAMPTZ,
      false,
      0::NUMERIC,
      10::INTEGER,
      5::INTEGER,
      1::INTEGER,
      false,
      false,
      false,
      '[]'::JSONB;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_service_subscription(UUID) TO anon, authenticated;

SELECT 'get_service_subscription — type mismatch price_paid corrigé.' AS status;
