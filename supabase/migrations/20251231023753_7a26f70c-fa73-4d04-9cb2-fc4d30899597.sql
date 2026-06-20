
-- Fix SECURITY DEFINER views by recreating them with security_invoker = true

-- 1. Fix bureau_taxi_drivers view
DROP VIEW IF EXISTS public.bureau_taxi_drivers;

CREATE VIEW public.bureau_taxi_drivers 
WITH (security_invoker = true)
AS
SELECT td.id,
    td.user_id,
    td.is_online,
    td.vehicle,
    td.rating,
    td.total_rides,
    td.total_earnings,
    td.created_at,
    td.updated_at,
    td.status,
    td.last_lat,
    td.last_lng,
    td.last_seen,
    td.vehicle_type,
    td.vehicle_plate,
    td.kyc_verified,
    td.can_work,
    td.last_heading,
    td.last_speed,
    td.bureau_id,
    td.syndicate_id,
    b.commune AS bureau_commune,
    b.prefecture AS bureau_prefecture,
    b.president_name AS bureau_president
FROM taxi_drivers td
LEFT JOIN bureaus b ON td.bureau_id = b.id;

-- Grant appropriate permissions
GRANT SELECT ON public.bureau_taxi_drivers TO authenticated;
GRANT SELECT ON public.bureau_taxi_drivers TO service_role;

-- 2. Fix security_policy_summary view
DROP VIEW IF EXISTS public.security_policy_summary;

CREATE VIEW public.security_policy_summary 
WITH (security_invoker = true)
AS
SELECT schemaname,
    tablename,
    count(*) AS policy_count,
    count(*) FILTER (WHERE roles::text ~~ '%anon%'::text) AS anon_policies,
    count(*) FILTER (WHERE roles::text ~~ '%authenticated%'::text) AS auth_policies
FROM pg_policies
WHERE schemaname = 'public'::name
GROUP BY schemaname, tablename
ORDER BY (count(*) FILTER (WHERE roles::text ~~ '%anon%'::text)) DESC;

-- Grant appropriate permissions (only to service_role for security view)
GRANT SELECT ON public.security_policy_summary TO service_role;
