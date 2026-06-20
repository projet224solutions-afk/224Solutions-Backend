
-- Batch 4b: Tables restantes avec relations

-- agents (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.agents;
CREATE POLICY "users_own_agents" ON public.agents FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- agents_management (pdg_id via pdg_management.user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.agents_management;
CREATE POLICY "pdg_own_agents_management" ON public.agents_management FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM pdg_management p WHERE p.id = agents_management.pdg_id AND p.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM pdg_management p WHERE p.id = agents_management.pdg_id AND p.user_id = auth.uid()));

-- audit_logs (actor_id)
DROP POLICY IF EXISTS "service_role_all" ON public.audit_logs;
CREATE POLICY "users_view_own_audit_logs" ON public.audit_logs FOR SELECT TO authenticated
USING (actor_id = auth.uid());

-- badges (bureau_id via bureaus.user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.badges;
CREATE POLICY "bureau_own_badges" ON public.badges FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM bureaus b WHERE b.id = badges.bureau_id AND b.user_id = auth.uid()) OR created_by = auth.uid()::text)
WITH CHECK (EXISTS (SELECT 1 FROM bureaus b WHERE b.id = badges.bureau_id AND b.user_id = auth.uid()) OR created_by = auth.uid()::text);

-- calls (caller_id, receiver_id)
DROP POLICY IF EXISTS "service_role_all" ON public.calls;
CREATE POLICY "users_own_calls" ON public.calls FOR ALL TO authenticated
USING (caller_id = auth.uid() OR receiver_id = auth.uid())
WITH CHECK (caller_id = auth.uid());

-- categories - lecture publique
DROP POLICY IF EXISTS "service_role_all" ON public.categories;
CREATE POLICY "authenticated_read_categories" ON public.categories FOR SELECT TO authenticated
USING (true);

-- commission_config - lecture seule
DROP POLICY IF EXISTS "service_role_all" ON public.commission_config;
CREATE POLICY "users_view_commission_config" ON public.commission_config FOR SELECT TO authenticated
USING (true);

-- customer_credits
DROP POLICY IF EXISTS "service_role_all" ON public.customer_credits;
CREATE POLICY "users_own_customer_credits" ON public.customer_credits FOR ALL TO authenticated
USING (customer_id = auth.uid() OR EXISTS (SELECT 1 FROM vendors v WHERE v.id = customer_credits.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = customer_credits.vendor_id AND v.user_id = auth.uid()));

-- deliveries
DROP POLICY IF EXISTS "service_role_all" ON public.deliveries;
CREATE POLICY "users_own_deliveries" ON public.deliveries FOR ALL TO authenticated
USING (driver_id = auth.uid() OR EXISTS (SELECT 1 FROM vendors v WHERE v.id = deliveries.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (driver_id = auth.uid() OR EXISTS (SELECT 1 FROM vendors v WHERE v.id = deliveries.vendor_id AND v.user_id = auth.uid()));

-- enhanced_transactions - lecture seule
DROP POLICY IF EXISTS "service_role_all" ON public.enhanced_transactions;
CREATE POLICY "authenticated_view_enhanced_transactions" ON public.enhanced_transactions FOR SELECT TO authenticated
USING (true);

-- escrows - lecture seule
DROP POLICY IF EXISTS "service_role_all" ON public.escrows;
CREATE POLICY "authenticated_view_escrows" ON public.escrows FOR SELECT TO authenticated
USING (true);

-- expense_analytics (vendor_id)
DROP POLICY IF EXISTS "service_role_all" ON public.expense_analytics;
CREATE POLICY "vendors_own_expense_analytics" ON public.expense_analytics FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = expense_analytics.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = expense_analytics.vendor_id AND v.user_id = auth.uid()));

-- expense_receipts - lecture seule
DROP POLICY IF EXISTS "service_role_all" ON public.expense_receipts;
CREATE POLICY "authenticated_view_expense_receipts" ON public.expense_receipts FOR SELECT TO authenticated
USING (true);

-- interactions
DROP POLICY IF EXISTS "service_role_all" ON public.interactions;
CREATE POLICY "users_own_interactions" ON public.interactions FOR ALL TO authenticated
USING (customer_id = auth.uid() OR EXISTS (SELECT 1 FROM vendors v WHERE v.id = interactions.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (customer_id = auth.uid() OR EXISTS (SELECT 1 FROM vendors v WHERE v.id = interactions.vendor_id AND v.user_id = auth.uid()));

-- international_shipments
DROP POLICY IF EXISTS "service_role_all" ON public.international_shipments;
CREATE POLICY "users_own_international_shipments" ON public.international_shipments FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM orders o WHERE o.id = international_shipments.order_id AND (o.customer_id = auth.uid() OR EXISTS (SELECT 1 FROM vendors v WHERE v.id = o.vendor_id AND v.user_id = auth.uid()))))
WITH CHECK (EXISTS (SELECT 1 FROM orders o WHERE o.id = international_shipments.order_id AND (o.customer_id = auth.uid() OR EXISTS (SELECT 1 FROM vendors v WHERE v.id = o.vendor_id AND v.user_id = auth.uid()))));

-- inventory
DROP POLICY IF EXISTS "service_role_all" ON public.inventory;
CREATE POLICY "vendors_own_inventory" ON public.inventory FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM products p JOIN vendors v ON v.id = p.vendor_id WHERE p.id = inventory.product_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM products p JOIN vendors v ON v.id = p.vendor_id WHERE p.id = inventory.product_id AND v.user_id = auth.uid()));

-- inventory_alerts
DROP POLICY IF EXISTS "service_role_alerts" ON public.inventory_alerts;
CREATE POLICY "vendors_own_inventory_alerts" ON public.inventory_alerts FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = inventory_alerts.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = inventory_alerts.vendor_id AND v.user_id = auth.uid()));

-- inventory_history
DROP POLICY IF EXISTS "service_role_history" ON public.inventory_history;
CREATE POLICY "users_own_inventory_history" ON public.inventory_history FOR ALL TO authenticated
USING (user_id = auth.uid() OR EXISTS (SELECT 1 FROM vendors v WHERE v.id = inventory_history.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (user_id = auth.uid() OR EXISTS (SELECT 1 FROM vendors v WHERE v.id = inventory_history.vendor_id AND v.user_id = auth.uid()));

-- marketing_campaigns
DROP POLICY IF EXISTS "service_role_all" ON public.marketing_campaigns;
CREATE POLICY "vendors_own_marketing_campaigns" ON public.marketing_campaigns FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = marketing_campaigns.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = marketing_campaigns.vendor_id AND v.user_id = auth.uid()));

-- payment_schedules
DROP POLICY IF EXISTS "service_role_all" ON public.payment_schedules;
CREATE POLICY "users_own_payment_schedules" ON public.payment_schedules FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM orders o WHERE o.id = payment_schedules.order_id AND (o.customer_id = auth.uid() OR EXISTS (SELECT 1 FROM vendors v WHERE v.id = o.vendor_id AND v.user_id = auth.uid()))))
WITH CHECK (EXISTS (SELECT 1 FROM orders o WHERE o.id = payment_schedules.order_id AND (o.customer_id = auth.uid() OR EXISTS (SELECT 1 FROM vendors v WHERE v.id = o.vendor_id AND v.user_id = auth.uid()))));

-- permissions - lecture seule
DROP POLICY IF EXISTS "service_role_all" ON public.permissions;
CREATE POLICY "authenticated_read_permissions" ON public.permissions FOR SELECT TO authenticated
USING (true);

-- pos_settings
DROP POLICY IF EXISTS "service_role_all" ON public.pos_settings;
CREATE POLICY "vendors_own_pos_settings" ON public.pos_settings FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = pos_settings.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = pos_settings.vendor_id AND v.user_id = auth.uid()));

-- product_variants
DROP POLICY IF EXISTS "service_role_all" ON public.product_variants;
CREATE POLICY "vendors_own_product_variants" ON public.product_variants FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM products p JOIN vendors v ON v.id = p.vendor_id WHERE p.id = product_variants.product_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM products p JOIN vendors v ON v.id = p.vendor_id WHERE p.id = product_variants.product_id AND v.user_id = auth.uid()));

-- products
DROP POLICY IF EXISTS "service_role_all" ON public.products;
CREATE POLICY "vendors_own_products" ON public.products FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = products.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = products.vendor_id AND v.user_id = auth.uid()));

-- promo_codes
DROP POLICY IF EXISTS "service_role_all" ON public.promo_codes;
CREATE POLICY "vendors_own_promo_codes" ON public.promo_codes FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = promo_codes.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = promo_codes.vendor_id AND v.user_id = auth.uid()));

-- promotions
DROP POLICY IF EXISTS "service_role_all" ON public.promotions;
CREATE POLICY "vendors_own_promotions" ON public.promotions FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = promotions.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = promotions.vendor_id AND v.user_id = auth.uid()));

-- prospects
DROP POLICY IF EXISTS "service_role_all" ON public.prospects;
CREATE POLICY "vendors_own_prospects" ON public.prospects FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = prospects.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = prospects.vendor_id AND v.user_id = auth.uid()));

-- rides
DROP POLICY IF EXISTS "service_role_all" ON public.rides;
CREATE POLICY "users_own_rides" ON public.rides FOR ALL TO authenticated
USING (customer_id = auth.uid() OR driver_id = auth.uid())
WITH CHECK (customer_id = auth.uid() OR driver_id = auth.uid());

-- roles - lecture seule
DROP POLICY IF EXISTS "service_role_all" ON public.roles;
CREATE POLICY "authenticated_read_roles" ON public.roles FOR SELECT TO authenticated
USING (true);

-- sos_alerts
DROP POLICY IF EXISTS "service_role_sos_access" ON public.sos_alerts;
CREATE POLICY "bureau_own_sos_alerts" ON public.sos_alerts FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM bureaus b WHERE b.id = sos_alerts.bureau_id AND b.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM bureaus b WHERE b.id = sos_alerts.bureau_id AND b.user_id = auth.uid()));

-- sos_media
DROP POLICY IF EXISTS "service_role_sos_media" ON public.sos_media;
CREATE POLICY "drivers_own_sos_media" ON public.sos_media FOR ALL TO authenticated
USING (driver_id = auth.uid())
WITH CHECK (driver_id = auth.uid());
