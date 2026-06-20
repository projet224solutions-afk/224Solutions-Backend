-- Batch 4g (v5): Colonnes correctes

-- drivers (user_id existe)
DROP POLICY IF EXISTS "Drivers can view their own data" ON public.drivers;
DROP POLICY IF EXISTS "Drivers can manage their data" ON public.drivers;
CREATE POLICY "Drivers can manage their data" ON public.drivers
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- favorites (customer_id existe, pas user_id)
DROP POLICY IF EXISTS "Users can manage their favorites" ON public.favorites;
CREATE POLICY "Users can manage their favorites" ON public.favorites
  FOR ALL TO authenticated
  USING (
    customer_id IN (SELECT id FROM public.customers WHERE user_id = auth.uid())
  )
  WITH CHECK (
    customer_id IN (SELECT id FROM public.customers WHERE user_id = auth.uid())
  );

-- currencies (table de référence - lecture seule pour tous)
DROP POLICY IF EXISTS "Anyone can view currencies" ON public.currencies;
CREATE POLICY "Anyone can view currencies" ON public.currencies
  FOR SELECT TO authenticated
  USING (true);

-- customers (user_id existe)
DROP POLICY IF EXISTS "Users can view customers" ON public.customers;
DROP POLICY IF EXISTS "Users can manage their customers" ON public.customers;
CREATE POLICY "Users can manage their customers" ON public.customers
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- debts (vendor_id existe)
DROP POLICY IF EXISTS "Users can manage their debts" ON public.debts;
CREATE POLICY "Users can manage their debts" ON public.debts
  FOR ALL TO authenticated
  USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  )
  WITH CHECK (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

-- deliveries (driver_id et vendor_id existent)
DROP POLICY IF EXISTS "Users can manage their deliveries" ON public.deliveries;
CREATE POLICY "Users can manage their deliveries" ON public.deliveries
  FOR ALL TO authenticated
  USING (
    driver_id IN (SELECT id FROM public.drivers WHERE user_id = auth.uid()) OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

-- delivery_logs (user_id existe)
DROP POLICY IF EXISTS "Users can view delivery logs" ON public.delivery_logs;
CREATE POLICY "Users can view delivery logs" ON public.delivery_logs
  FOR ALL TO authenticated
  USING (user_id = auth.uid());

-- delivery_notifications (user_id existe)
DROP POLICY IF EXISTS "Users can view their delivery notifications" ON public.delivery_notifications;
CREATE POLICY "Users can view their delivery notifications" ON public.delivery_notifications
  FOR ALL TO authenticated
  USING (user_id = auth.uid());

-- delivery_offers (driver_id existe)
DROP POLICY IF EXISTS "Users can manage delivery offers" ON public.delivery_offers;
CREATE POLICY "Users can manage delivery offers" ON public.delivery_offers
  FOR ALL TO authenticated
  USING (
    driver_id IN (SELECT id FROM public.drivers WHERE user_id = auth.uid())
  )
  WITH CHECK (
    driver_id IN (SELECT id FROM public.drivers WHERE user_id = auth.uid())
  );

-- delivery_tracking (driver_id existe)
DROP POLICY IF EXISTS "Users can view delivery tracking" ON public.delivery_tracking;
CREATE POLICY "Users can view delivery tracking" ON public.delivery_tracking
  FOR ALL TO authenticated
  USING (
    driver_id IN (SELECT id FROM public.drivers WHERE user_id = auth.uid())
  );

-- digital_products (vendor_id existe)
DROP POLICY IF EXISTS "Vendors can manage digital products" ON public.digital_products;
CREATE POLICY "Vendors can manage digital products" ON public.digital_products
  FOR ALL TO authenticated
  USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  )
  WITH CHECK (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

-- disputes (vendor_id existe)
DROP POLICY IF EXISTS "Vendors can manage disputes" ON public.disputes;
CREATE POLICY "Vendors can manage disputes" ON public.disputes
  FOR ALL TO authenticated
  USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

-- driver_subscriptions (user_id existe)
DROP POLICY IF EXISTS "Users can manage driver subscriptions" ON public.driver_subscriptions;
CREATE POLICY "Users can manage driver subscriptions" ON public.driver_subscriptions
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- driver_subscription_revenues (user_id existe)
DROP POLICY IF EXISTS "Users can view subscription revenues" ON public.driver_subscription_revenues;
CREATE POLICY "Users can view subscription revenues" ON public.driver_subscription_revenues
  FOR ALL TO authenticated
  USING (user_id = auth.uid());