BEGIN;

-- ════════════════════════════════════════════════════════════
-- 1. get_service_subscription ENRICHI (tous les flags)
-- ════════════════════════════════════════════════════════════
DROP FUNCTION IF EXISTS public.get_service_subscription(uuid);

CREATE OR REPLACE FUNCTION public.get_service_subscription(p_service_id uuid)
RETURNS TABLE(
  subscription_id     UUID,
  plan_id             UUID,
  plan_name           TEXT,
  plan_display_name   TEXT,
  status              TEXT,
  current_period_end  TIMESTAMPTZ,
  auto_renew          BOOLEAN,
  price_paid          INTEGER,
  max_bookings        INTEGER,
  max_products        INTEGER,
  max_staff           INTEGER,
  priority_listing    BOOLEAN,
  analytics_access    BOOLEAN,
  can_upload_video    BOOLEAN,
  sms_notifications   BOOLEAN,
  email_notifications BOOLEAN,
  custom_branding     BOOLEAN,
  api_access          BOOLEAN,
  features            JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- a) Abonnement ACTIF (payant, non expiré)
  RETURN QUERY
  SELECT
    ss.id, sp.id, sp.name::TEXT, sp.display_name::TEXT, ss.status::TEXT,
    ss.current_period_end, COALESCE(ss.auto_renew, false), COALESCE(ss.price_paid_gnf, 0),
    sp.max_bookings_per_month, sp.max_products, sp.max_staff,
    COALESCE(sp.priority_listing, false), COALESCE(sp.analytics_access, false),
    COALESCE(sp.can_upload_video, false), COALESCE(sp.sms_notifications, false),
    COALESCE(sp.email_notifications, true), COALESCE(sp.custom_branding, false),
    COALESCE(sp.api_access, false), sp.features
  FROM public.service_subscriptions ss
  JOIN public.service_plans sp ON sp.id = ss.plan_id
  WHERE ss.professional_service_id = p_service_id
    AND ss.status = 'active'
    AND (ss.current_period_end IS NULL OR ss.current_period_end >= now())
  ORDER BY ss.created_at DESC
  LIMIT 1;

  -- b) Aucun abonnement actif → PLAN GRATUIT (plancher)
  IF NOT FOUND THEN
    RETURN QUERY
    SELECT
      NULL::UUID, sp.id, sp.name::TEXT, sp.display_name::TEXT, 'free'::TEXT,
      NULL::TIMESTAMPTZ, false, 0,
      sp.max_bookings_per_month, sp.max_products, sp.max_staff,
      COALESCE(sp.priority_listing, false), COALESCE(sp.analytics_access, false),
      COALESCE(sp.can_upload_video, false), COALESCE(sp.sms_notifications, false),
      COALESCE(sp.email_notifications, true), COALESCE(sp.custom_branding, false),
      COALESCE(sp.api_access, false), sp.features
    FROM public.service_plans sp
    WHERE sp.name = 'free'
    LIMIT 1;
  END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_service_subscription(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_service_subscription(uuid) TO authenticated, service_role;

-- ════════════════════════════════════════════════════════════
-- 2. get_effective_service_limits — limites EFFECTIVES garanties
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.get_effective_service_limits(p_service_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row record;
  v_is_paid boolean;
BEGIN
  SELECT * INTO v_row FROM public.get_service_subscription(p_service_id) LIMIT 1;

  IF v_row IS NULL THEN
    RETURN jsonb_build_object(
      'plan_name', 'free', 'is_paid', false, 'is_active', false,
      'max_bookings', 10, 'max_products', 5, 'max_staff', 1,
      'priority_listing', false, 'analytics_access', false, 'can_upload_video', false,
      'sms_notifications', false, 'email_notifications', true,
      'custom_branding', false, 'api_access', false
    );
  END IF;

  v_is_paid := v_row.subscription_id IS NOT NULL;

  RETURN jsonb_build_object(
    'plan_name',         v_row.plan_name,
    'is_paid',           v_is_paid,
    'is_active',         v_is_paid,
    'current_period_end',v_row.current_period_end,
    'max_bookings',      v_row.max_bookings,
    'max_products',      v_row.max_products,
    'max_staff',         v_row.max_staff,
    'priority_listing',  v_row.priority_listing,
    'analytics_access',  v_row.analytics_access,
    'can_upload_video',  v_row.can_upload_video,
    'sms_notifications', v_row.sms_notifications,
    'email_notifications', v_row.email_notifications,
    'custom_branding',   v_row.custom_branding,
    'api_access',        v_row.api_access
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_effective_service_limits(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_effective_service_limits(uuid) TO authenticated, service_role;

-- ════════════════════════════════════════════════════════════
-- 3. Garde-fou
-- ════════════════════════════════════════════════════════════
DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='get_effective_service_limits')
  THEN RAISE EXCEPTION 'get_effective_service_limits absente'; END IF;
  PERFORM 1 FROM pg_proc p
    WHERE p.proname='get_service_subscription'
      AND pg_get_function_result(p.oid) LIKE '%sms_notifications%';
  IF NOT FOUND THEN RAISE EXCEPTION 'get_service_subscription n''expose pas sms_notifications'; END IF;
  RAISE NOTICE '✅ Migration service_subscription_full_flags OK';
END; $$;

COMMIT;
