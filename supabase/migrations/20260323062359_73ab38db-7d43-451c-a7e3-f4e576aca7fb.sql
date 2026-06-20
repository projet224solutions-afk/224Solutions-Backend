-- 1. Fix: stripe_config - supprimer la policy permissive qui expose les secrets
DROP POLICY IF EXISTS "authenticated_read_stripe_config" ON stripe_config;

-- 2. Fix: commission_settings - restreindre UPDATE aux PDG uniquement
DROP POLICY IF EXISTS "Only authenticated users can update commission settings" ON commission_settings;
CREATE POLICY "pdg_update_commission_settings" ON commission_settings
FOR UPDATE TO authenticated
USING (EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid() AND is_active = true))
WITH CHECK (EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid() AND is_active = true));

-- 3. Fix: shop_visits_raw - restreindre l'accès public
DROP POLICY IF EXISTS "Service role can manage shop_visits_raw" ON shop_visits_raw;
CREATE POLICY "service_role_manage_shop_visits_raw" ON shop_visits_raw
FOR ALL TO service_role
USING (true)
WITH CHECK (true);
CREATE POLICY "vendors_read_own_shop_visits" ON shop_visits_raw
FOR SELECT TO authenticated
USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

-- 4. Fix: user_behavior_sessions - restreindre aux propres données
DROP POLICY IF EXISTS "Users can read their own behavior" ON user_behavior_sessions;
CREATE POLICY "users_read_own_behavior" ON user_behavior_sessions
FOR SELECT TO authenticated
USING (user_id = auth.uid());