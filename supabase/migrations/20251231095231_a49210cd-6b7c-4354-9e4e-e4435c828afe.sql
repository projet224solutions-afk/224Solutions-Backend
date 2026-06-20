
-- FIX CRITIQUE: Résoudre la récursion infinie sur orders et customers

-- ==========================================
-- ÉTAPE 1: Nettoyer toutes les politiques orders (13 → 2)
-- ==========================================
DROP POLICY IF EXISTS "Admins can view all orders" ON public.orders;
DROP POLICY IF EXISTS "Authenticated users can create orders" ON public.orders;
DROP POLICY IF EXISTS "Clients can create their own orders" ON public.orders;
DROP POLICY IF EXISTS "Customers can view their orders" ON public.orders;
DROP POLICY IF EXISTS "Customers can view their own orders" ON public.orders;
DROP POLICY IF EXISTS "Public can create orders" ON public.orders;
DROP POLICY IF EXISTS "Vendors can manage their orders" ON public.orders;
DROP POLICY IF EXISTS "Vendors can update their orders" ON public.orders;
DROP POLICY IF EXISTS "authenticated_users_view_own_orders" ON public.orders;
DROP POLICY IF EXISTS "customers_can_view_their_orders" ON public.orders;
DROP POLICY IF EXISTS "users_own_orders" ON public.orders;
DROP POLICY IF EXISTS "vendors_can_update_their_orders" ON public.orders;
DROP POLICY IF EXISTS "vendors_can_view_their_orders" ON public.orders;

-- Nouvelle politique SIMPLE sans récursion (utilise directement les IDs)
CREATE POLICY "orders_select_policy" ON public.orders
  FOR SELECT TO authenticated
  USING (
    customer_id = auth.uid() OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "orders_insert_policy" ON public.orders
  FOR INSERT TO authenticated
  WITH CHECK (
    customer_id = auth.uid() OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "orders_update_policy" ON public.orders
  FOR UPDATE TO authenticated
  USING (
    customer_id = auth.uid() OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  )
  WITH CHECK (
    customer_id = auth.uid() OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "orders_delete_policy" ON public.orders
  FOR DELETE TO authenticated
  USING (
    customer_id = auth.uid() OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

-- ==========================================
-- ÉTAPE 2: Nettoyer toutes les politiques customers (5 → 1)
-- ==========================================
DROP POLICY IF EXISTS "Admins view all customers" ON public.customers;
DROP POLICY IF EXISTS "Users can manage their customers" ON public.customers;
DROP POLICY IF EXISTS "Users manage own customer profile" ON public.customers;
DROP POLICY IF EXISTS "Vendors view own customers" ON public.customers;
DROP POLICY IF EXISTS "users_own_customers" ON public.customers;

-- Nouvelle politique SIMPLE sans récursion
CREATE POLICY "customers_own_profile" ON public.customers
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Les vendeurs peuvent voir les clients de leurs commandes (sans récursion)
CREATE POLICY "vendors_view_order_customers" ON public.customers
  FOR SELECT TO authenticated
  USING (
    id IN (
      SELECT DISTINCT o.customer_id 
      FROM public.orders o
      WHERE o.vendor_id IN (SELECT v.id FROM public.vendors v WHERE v.user_id = auth.uid())
    )
  );
