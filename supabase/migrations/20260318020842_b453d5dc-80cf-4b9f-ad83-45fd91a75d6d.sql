-- ============================================================
-- 1. Security definer function: check if current user is an 
--    active vendor agent for a given vendor
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_vendor_agent_of(check_vendor_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.vendor_agents
    WHERE user_id = auth.uid()
      AND vendor_id = check_vendor_id
      AND is_active = true
  )
$$;

-- Helper: check if current user is vendor owner OR active agent
CREATE OR REPLACE FUNCTION public.is_vendor_or_agent(check_vendor_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.vendors
    WHERE id = check_vendor_id AND user_id = auth.uid()
  )
  OR EXISTS (
    SELECT 1 FROM public.vendor_agents
    WHERE user_id = auth.uid()
      AND vendor_id = check_vendor_id
      AND is_active = true
  )
$$;

-- ============================================================
-- 2. ORDERS - Update SELECT policy
-- ============================================================
DROP POLICY IF EXISTS "orders_select_policy" ON public.orders;
CREATE POLICY "orders_select_policy" ON public.orders
  FOR SELECT TO authenticated
  USING (
    customer_belongs_to_auth_user(customer_id)
    OR public.is_vendor_or_agent(vendor_id)
    OR EXISTS (SELECT 1 FROM pdg_management p WHERE p.user_id = auth.uid())
  );

-- ORDERS - Update UPDATE policy
DROP POLICY IF EXISTS "orders_update_policy" ON public.orders;
CREATE POLICY "orders_update_policy" ON public.orders
  FOR UPDATE TO authenticated
  USING (
    customer_belongs_to_auth_user(customer_id)
    OR public.is_vendor_or_agent(vendor_id)
    OR EXISTS (SELECT 1 FROM pdg_management p WHERE p.user_id = auth.uid())
  );

-- ORDERS - Update DELETE policy
DROP POLICY IF EXISTS "orders_delete_policy" ON public.orders;
CREATE POLICY "orders_delete_policy" ON public.orders
  FOR DELETE TO authenticated
  USING (
    customer_belongs_to_auth_user(customer_id)
    OR public.is_vendor_or_agent(vendor_id)
    OR EXISTS (SELECT 1 FROM pdg_management p WHERE p.user_id = auth.uid())
  );

-- ORDERS - Drop old duplicate SELECT policy
DROP POLICY IF EXISTS "vendors_view_own_orders" ON public.orders;

-- ============================================================
-- 3. PRODUCTS - Update vendor manage policy
-- ============================================================
DROP POLICY IF EXISTS "Vendors can manage own products" ON public.products;
CREATE POLICY "Vendors can manage own products" ON public.products
  FOR ALL TO authenticated
  USING (public.is_vendor_or_agent(vendor_id));

DROP POLICY IF EXISTS "vendors_own_products" ON public.products;
DROP POLICY IF EXISTS "vendors_manage_own_products" ON public.products;

-- ============================================================
-- 4. INVENTORY - Update vendor manage policy
-- ============================================================
DROP POLICY IF EXISTS "vendors_own_inventory" ON public.inventory;
CREATE POLICY "vendors_own_inventory" ON public.inventory
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM products p
      WHERE p.id = inventory.product_id
        AND public.is_vendor_or_agent(p.vendor_id)
    )
  );

-- ============================================================
-- 5. ORDER_ITEMS - Update vendor policy
-- ============================================================
DROP POLICY IF EXISTS "vendors_own_order_items" ON public.order_items;
CREATE POLICY "vendors_own_order_items" ON public.order_items
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM orders o
      WHERE o.id = order_items.order_id
        AND public.is_vendor_or_agent(o.vendor_id)
    )
  );

-- ============================================================
-- 6. CUSTOMERS - Update vendor view policy
-- ============================================================
DROP POLICY IF EXISTS "vendors_view_order_customers" ON public.customers;
CREATE POLICY "vendors_view_order_customers" ON public.customers
  FOR SELECT TO authenticated
  USING (
    id IN (
      SELECT DISTINCT o.customer_id
      FROM orders o
      WHERE public.is_vendor_or_agent(o.vendor_id)
    )
  );

-- ============================================================
-- 7. VENDOR_SUPPLIERS - Update policies
-- ============================================================
DROP POLICY IF EXISTS "Vendors can view their own suppliers" ON public.vendor_suppliers;
CREATE POLICY "Vendors can view their own suppliers" ON public.vendor_suppliers
  FOR SELECT TO authenticated
  USING (public.is_vendor_or_agent(vendor_id));

DROP POLICY IF EXISTS "Vendors can update their own suppliers" ON public.vendor_suppliers;
CREATE POLICY "Vendors can update their own suppliers" ON public.vendor_suppliers
  FOR UPDATE TO authenticated
  USING (public.is_vendor_or_agent(vendor_id));

DROP POLICY IF EXISTS "Vendors can delete suppliers without validated purchases" ON public.vendor_suppliers;
CREATE POLICY "Vendors can delete suppliers without validated purchases" ON public.vendor_suppliers
  FOR DELETE TO authenticated
  USING (public.is_vendor_or_agent(vendor_id) AND has_validated_purchases = false);

DROP POLICY IF EXISTS "Vendors can create their own suppliers" ON public.vendor_suppliers;
CREATE POLICY "Vendors can create their own suppliers" ON public.vendor_suppliers
  FOR INSERT TO authenticated
  WITH CHECK (public.is_vendor_or_agent(vendor_id));

-- ============================================================
-- 8. ANALYTICS_DAILY_STATS - Update policy
-- ============================================================
DROP POLICY IF EXISTS "Vendors can view their own daily stats" ON public.analytics_daily_stats;
CREATE POLICY "Vendors can view their own daily stats" ON public.analytics_daily_stats
  FOR SELECT TO authenticated
  USING (public.is_vendor_or_agent(vendor_id));

-- ============================================================
-- 9. PAYMENT_LINKS - Update delete policy
-- ============================================================
DROP POLICY IF EXISTS "Vendors can delete their own payment links" ON public.payment_links;
CREATE POLICY "Vendors can delete their own payment links" ON public.payment_links
  FOR DELETE TO authenticated
  USING (public.is_vendor_or_agent(vendeur_id));

-- ============================================================
-- 10. SUPPORT_TICKETS - Update vendor policy
-- ============================================================
DROP POLICY IF EXISTS "Vendors can view tickets assigned to them" ON public.support_tickets;
CREATE POLICY "Vendors can view tickets assigned to them" ON public.support_tickets
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM vendors
      WHERE vendors.id = support_tickets.vendor_id
        AND (vendors.user_id = auth.uid() OR public.is_vendor_agent_of(support_tickets.vendor_id))
    )
  );

DROP POLICY IF EXISTS "users_own_support_tickets" ON public.support_tickets;
CREATE POLICY "users_own_support_tickets" ON public.support_tickets
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM vendors v
      WHERE v.id = support_tickets.vendor_id
        AND (v.user_id = auth.uid() OR public.is_vendor_agent_of(support_tickets.vendor_id))
    )
  );

-- ============================================================
-- 11. VENDOR_EXPENSES - Ensure agents can access
-- ============================================================
DROP POLICY IF EXISTS "Vendors can manage their expenses" ON public.vendor_expenses;
CREATE POLICY "Vendors can manage their expenses" ON public.vendor_expenses
  FOR ALL TO authenticated
  USING (public.is_vendor_or_agent(vendor_id));
