
-- Batch 4a: Tables avec user_id direct et confirmé

-- drivers (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.drivers;
CREATE POLICY "users_own_drivers" ON public.drivers FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- customers (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.customers;
CREATE POLICY "users_own_customers" ON public.customers FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- trackings (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.trackings;
CREATE POLICY "users_own_trackings" ON public.trackings FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- user_ids (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.user_ids;
CREATE POLICY "users_own_user_ids" ON public.user_ids FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- fraud_detection_logs (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.fraud_detection_logs;
CREATE POLICY "users_view_own_fraud_logs" ON public.fraud_detection_logs FOR SELECT TO authenticated
USING (user_id = auth.uid());

-- carts (customer_id - pas user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.carts;
CREATE POLICY "customers_own_carts" ON public.carts FOR ALL TO authenticated
USING (customer_id = auth.uid())
WITH CHECK (customer_id = auth.uid());

-- copilot_conversations (pdg_user_id - pas user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.copilot_conversations;
CREATE POLICY "users_own_copilot_conversations" ON public.copilot_conversations FOR ALL TO authenticated
USING (pdg_user_id = auth.uid())
WITH CHECK (pdg_user_id = auth.uid());

-- bureaus (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.bureaus;
CREATE POLICY "users_own_bureaus" ON public.bureaus FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- vendors (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.vendors;
CREATE POLICY "users_own_vendors" ON public.vendors FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- virtual_cards (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.virtual_cards;
CREATE POLICY "users_own_virtual_cards" ON public.virtual_cards FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- pdg_management (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.pdg_management;
CREATE POLICY "users_own_pdg_management" ON public.pdg_management FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- taxi_drivers (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.taxi_drivers;
CREATE POLICY "users_own_taxi_drivers" ON public.taxi_drivers FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());
