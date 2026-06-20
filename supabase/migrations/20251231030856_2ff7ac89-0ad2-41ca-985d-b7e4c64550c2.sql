
-- Batch 3: Tables O-Z avec colonnes correctes

-- order_items (via orders.vendor_id)
DROP POLICY IF EXISTS "service_role_all" ON public.order_items;
CREATE POLICY "vendors_own_order_items" ON public.order_items FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM orders o JOIN vendors v ON v.id = o.vendor_id WHERE o.id = order_items.order_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM orders o JOIN vendors v ON v.id = o.vendor_id WHERE o.id = order_items.order_id AND v.user_id = auth.uid()));

-- orders (customer_id ou vendor_id)
DROP POLICY IF EXISTS "service_role_all" ON public.orders;
CREATE POLICY "users_own_orders" ON public.orders FOR ALL TO authenticated
USING (customer_id = auth.uid() OR EXISTS (SELECT 1 FROM vendors v WHERE v.id = orders.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (customer_id = auth.uid() OR EXISTS (SELECT 1 FROM vendors v WHERE v.id = orders.vendor_id AND v.user_id = auth.uid()));

-- p2p_transactions (sender_id, receiver_id)
DROP POLICY IF EXISTS "service_role_all" ON public.p2p_transactions;
CREATE POLICY "users_own_p2p_transactions" ON public.p2p_transactions FOR ALL TO authenticated
USING (sender_id = auth.uid() OR receiver_id = auth.uid())
WITH CHECK (sender_id = auth.uid());

-- payment_methods (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.payment_methods;
CREATE POLICY "users_own_payment_methods" ON public.payment_methods FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- quotes (vendor_id via vendors)
DROP POLICY IF EXISTS "service_role_all" ON public.quotes;
CREATE POLICY "vendors_own_quotes" ON public.quotes FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = quotes.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = quotes.vendor_id AND v.user_id = auth.uid()));

-- reviews (customer_id)
DROP POLICY IF EXISTS "service_role_all" ON public.reviews;
CREATE POLICY "customers_own_reviews" ON public.reviews FOR ALL TO authenticated
USING (customer_id = auth.uid())
WITH CHECK (customer_id = auth.uid());

-- sales (vendor_id via vendors)
DROP POLICY IF EXISTS "service_role_all" ON public.sales;
CREATE POLICY "vendors_own_sales" ON public.sales FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = sales.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = sales.vendor_id AND v.user_id = auth.uid()));

-- subscriptions (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.subscriptions;
CREATE POLICY "users_own_subscriptions" ON public.subscriptions FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- support_tickets (user_id ou vendor_id)
DROP POLICY IF EXISTS "service_role_all" ON public.support_tickets;
CREATE POLICY "users_own_support_tickets" ON public.support_tickets FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM vendors v WHERE v.id = support_tickets.vendor_id AND v.user_id = auth.uid()))
WITH CHECK (EXISTS (SELECT 1 FROM vendors v WHERE v.id = support_tickets.vendor_id AND v.user_id = auth.uid()));

-- transactions (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.transactions;
CREATE POLICY "users_own_transactions" ON public.transactions FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- wallets (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.wallets;
DROP POLICY IF EXISTS "service_role_all_wallets" ON public.wallets;
CREATE POLICY "users_own_wallets" ON public.wallets FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- wishlists (user_id)
DROP POLICY IF EXISTS "service_role_all" ON public.wishlists;
CREATE POLICY "users_own_wishlists" ON public.wishlists FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());
