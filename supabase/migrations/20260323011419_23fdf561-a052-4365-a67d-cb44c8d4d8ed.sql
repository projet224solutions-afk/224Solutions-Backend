DROP FUNCTION IF EXISTS get_service_subscription(UUID);

CREATE OR REPLACE FUNCTION get_service_subscription(p_service_id UUID)
RETURNS TABLE(
  subscription_id UUID,
  plan_id UUID,
  plan_name TEXT,
  plan_display_name TEXT,
  status TEXT,
  current_period_end TIMESTAMPTZ,
  auto_renew BOOLEAN,
  price_paid NUMERIC,
  max_bookings INTEGER,
  max_products INTEGER,
  max_staff INTEGER,
  priority_listing BOOLEAN,
  analytics_access BOOLEAN,
  features JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    ss.id as subscription_id,
    sp.id as plan_id,
    sp.name::TEXT as plan_name,
    sp.display_name::TEXT as plan_display_name,
    ss.status::TEXT,
    ss.current_period_end,
    ss.auto_renew,
    ss.price_paid_gnf as price_paid,
    sp.max_bookings_per_month as max_bookings,
    sp.max_products,
    sp.max_staff,
    sp.priority_listing,
    sp.analytics_access,
    sp.features
  FROM service_subscriptions ss
  JOIN service_plans sp ON ss.plan_id = sp.id
  WHERE ss.professional_service_id = p_service_id
    AND ss.status = 'active'
    AND ss.current_period_end > now()
  ORDER BY ss.created_at DESC
  LIMIT 1;
  
  IF NOT FOUND THEN
    RETURN QUERY
    SELECT 
      NULL::UUID as subscription_id,
      sp.id as plan_id,
      sp.name::TEXT as plan_name,
      sp.display_name::TEXT as plan_display_name,
      'free'::TEXT as status,
      NULL::TIMESTAMPTZ as current_period_end,
      false as auto_renew,
      0::NUMERIC as price_paid,
      sp.max_bookings_per_month as max_bookings,
      sp.max_products,
      sp.max_staff,
      sp.priority_listing,
      sp.analytics_access,
      sp.features
    FROM service_plans sp
    JOIN professional_services ps ON ps.service_type_id = sp.service_type_id
    WHERE sp.name = 'free'
      AND ps.id = p_service_id
    LIMIT 1;
  END IF;
  
  IF NOT FOUND THEN
    RETURN QUERY
    SELECT 
      NULL::UUID as subscription_id,
      NULL::UUID as plan_id,
      'free'::TEXT as plan_name,
      'Gratuit'::TEXT as plan_display_name,
      'free'::TEXT as status,
      NULL::TIMESTAMPTZ as current_period_end,
      false as auto_renew,
      0::NUMERIC as price_paid,
      10::INTEGER as max_bookings,
      2::INTEGER as max_products,
      1::INTEGER as max_staff,
      false as priority_listing,
      false as analytics_access,
      '["Profil public", "Dashboard simple"]'::JSONB as features;
  END IF;
END;
$$