-- 1. DROP the overly permissive policy on user_roles that allows privilege escalation
DROP POLICY IF EXISTS "Admins can manage user roles" ON public.user_roles;

-- 2. Fix product_views_raw: drop the public-facing policy and create service_role only
DROP POLICY IF EXISTS "Service role can manage product_views_raw" ON public.product_views_raw;
CREATE POLICY "Service role can manage product_views_raw" ON public.product_views_raw FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "Users can insert own views" ON public.product_views_raw FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

-- 3. Fix security infrastructure tables: drop overly broad ALL policies
DROP POLICY IF EXISTS "Admins security alerts" ON public.security_alerts;
DROP POLICY IF EXISTS "Admins security keys" ON public.security_keys;
DROP POLICY IF EXISTS "Admins snapshots" ON public.security_snapshots;
DROP POLICY IF EXISTS "Admins playbooks" ON public.security_playbooks;
DROP POLICY IF EXISTS "Admins audit logs" ON public.security_audit_logs;

-- 4. Fix profiles: drop the overly permissive search policy
DROP POLICY IF EXISTS "users_can_search_profiles_for_messaging" ON public.profiles;