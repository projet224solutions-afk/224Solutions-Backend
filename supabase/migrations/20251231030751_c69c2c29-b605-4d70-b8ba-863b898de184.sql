
-- Batch 2: Tables D-N avec colonnes correctes

-- delivery_messages (sender_id, recipient_id)
DROP POLICY IF EXISTS "service_role_all" ON public.delivery_messages;
CREATE POLICY "users_own_delivery_messages" ON public.delivery_messages FOR ALL TO authenticated
USING (sender_id = auth.uid() OR recipient_id = auth.uid())
WITH CHECK (sender_id = auth.uid());

-- delivery_notifications (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.delivery_notifications;
CREATE POLICY "users_own_delivery_notifications" ON public.delivery_notifications FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- delivery_offers (driver_id)
DROP POLICY IF EXISTS "service_role_all" ON public.delivery_offers;
CREATE POLICY "drivers_own_delivery_offers" ON public.delivery_offers FOR ALL TO authenticated
USING (driver_id = auth.uid())
WITH CHECK (driver_id = auth.uid());

-- digital_products (vendor_id via vendors)
DROP POLICY IF EXISTS "service_role_all" ON public.digital_products;
CREATE POLICY "vendors_own_digital_products" ON public.digital_products FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = digital_products.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = digital_products.vendor_id AND v.user_id = auth.uid()));

-- digital_product_purchases (buyer_id)
DROP POLICY IF EXISTS "service_role_all" ON public.digital_product_purchases;
CREATE POLICY "buyers_own_purchases" ON public.digital_product_purchases FOR ALL TO authenticated
USING (buyer_id = auth.uid())
WITH CHECK (buyer_id = auth.uid());

-- driver_subscriptions (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.driver_subscriptions;
CREATE POLICY "users_own_driver_subscriptions" ON public.driver_subscriptions FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- education_courses (professional_service_id via professional_services)
DROP POLICY IF EXISTS "service_role_all" ON public.education_courses;
CREATE POLICY "owners_manage_education_courses" ON public.education_courses FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM professional_services ps WHERE ps.id = education_courses.professional_service_id AND ps.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM professional_services ps WHERE ps.id = education_courses.professional_service_id AND ps.user_id = auth.uid()));

-- expense_alerts (vendor_id via vendors)
DROP POLICY IF EXISTS "service_role_all" ON public.expense_alerts;
CREATE POLICY "vendors_own_expense_alerts" ON public.expense_alerts FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = expense_alerts.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = expense_alerts.vendor_id AND v.user_id = auth.uid()));

-- expense_budgets (vendor_id via vendors)
DROP POLICY IF EXISTS "service_role_all" ON public.expense_budgets;
CREATE POLICY "vendors_own_expense_budgets" ON public.expense_budgets FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = expense_budgets.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = expense_budgets.vendor_id AND v.user_id = auth.uid()));

-- expense_categories (vendor_id via vendors)
DROP POLICY IF EXISTS "service_role_all" ON public.expense_categories;
CREATE POLICY "vendors_own_expense_categories" ON public.expense_categories FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = expense_categories.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = expense_categories.vendor_id AND v.user_id = auth.uid()));

-- favorites (customer_id)
DROP POLICY IF EXISTS "service_role_all" ON public.favorites;
CREATE POLICY "customers_own_favorites" ON public.favorites FOR ALL TO authenticated
USING (customer_id = auth.uid())
WITH CHECK (customer_id = auth.uid());

-- generated_reports (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.generated_reports;
CREATE POLICY "users_own_generated_reports" ON public.generated_reports FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- members (bureau_id via bureaus)
DROP POLICY IF EXISTS "service_role_all" ON public.members;
CREATE POLICY "bureau_owners_manage_members" ON public.members FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM bureaus b WHERE b.id = members.bureau_id AND b.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM bureaus b WHERE b.id = members.bureau_id AND b.user_id = auth.uid()));

-- messages (sender_id, recipient_id)
DROP POLICY IF EXISTS "service_role_all" ON public.messages;
CREATE POLICY "users_own_messages" ON public.messages FOR ALL TO authenticated
USING (sender_id = auth.uid() OR recipient_id = auth.uid())
WITH CHECK (sender_id = auth.uid());

-- notifications (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.notifications;
CREATE POLICY "users_own_notifications" ON public.notifications FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());
