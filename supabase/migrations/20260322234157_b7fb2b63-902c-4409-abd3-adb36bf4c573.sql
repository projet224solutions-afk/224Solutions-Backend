
-- FIX: Drop overly permissive public SELECT policy on stripe_config
DROP POLICY IF EXISTS "stripe_config_public" ON stripe_config;

-- Replace with authenticated-only read policy
CREATE POLICY "authenticated_read_stripe_config" ON stripe_config
FOR SELECT TO authenticated
USING (true);
