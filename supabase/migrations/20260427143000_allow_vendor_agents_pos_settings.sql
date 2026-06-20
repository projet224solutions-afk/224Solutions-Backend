-- Allow active vendor agents to read/update POS settings for their assigned vendor.
DROP POLICY IF EXISTS "vendors_own_pos_settings" ON public.pos_settings;

CREATE POLICY "vendors_and_agents_own_pos_settings"
ON public.pos_settings
FOR ALL TO authenticated
USING (public.is_vendor_or_agent(vendor_id))
WITH CHECK (public.is_vendor_or_agent(vendor_id));

-- POS card/mobile-money flows create an order before payment confirmation.
-- Active vendor agents with POS permission must be able to create orders for
-- their assigned vendor, not only update existing orders.
DROP POLICY IF EXISTS "orders_insert_policy" ON public.orders;

CREATE POLICY "orders_insert_policy"
ON public.orders
FOR INSERT TO authenticated
WITH CHECK (
  public.customer_belongs_to_auth_user(customer_id)
  OR public.is_vendor_or_agent(vendor_id)
  OR EXISTS (SELECT 1 FROM public.pdg_management p WHERE p.user_id = auth.uid())
);
