-- =====================================================
-- SECURITY FIX: Restrict policies to authenticated users only
-- =====================================================

-- === API KEYS (Sensitive credentials) ===
DROP POLICY IF EXISTS "Users can delete their own API keys" ON public.api_keys;
DROP POLICY IF EXISTS "Users can update their own API keys" ON public.api_keys;
DROP POLICY IF EXISTS "Users can view their own API keys" ON public.api_keys;

CREATE POLICY "authenticated_users_manage_own_api_keys" ON public.api_keys
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- === CARTS (User data) ===
DROP POLICY IF EXISTS "Authenticated users manage their cart" ON public.advanced_carts;

CREATE POLICY "authenticated_users_manage_own_cart" ON public.advanced_carts
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- === AUDIT LOGS (Admin only) ===
DROP POLICY IF EXISTS "PDG only access audit_logs" ON public.audit_logs;

CREATE POLICY "authenticated_admins_view_audit_logs" ON public.audit_logs
  FOR SELECT TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo'))
  );

-- === TRANSACTIONS (Financial - user_id based) ===
DROP POLICY IF EXISTS "Utilisateurs peuvent voir leurs transactions" ON public.transactions;
DROP POLICY IF EXISTS "Users can view their wallet transactions" ON public.transactions;

CREATE POLICY "authenticated_users_view_own_transactions" ON public.transactions
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid() OR
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo'))
  );

-- === WALLETS (User wallets - CRITICAL) ===
DROP POLICY IF EXISTS "Users can view their own wallet" ON public.wallets;
DROP POLICY IF EXISTS "wallet_select" ON public.wallets;

CREATE POLICY "authenticated_users_view_own_wallet" ON public.wallets
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid() OR
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo'))
  );

-- === PROFILES (Authenticated users only) ===
DROP POLICY IF EXISTS "Profiles are viewable by everyone" ON public.profiles;

CREATE POLICY "authenticated_users_view_profiles" ON public.profiles
  FOR SELECT TO authenticated
  USING (true);

-- === ORDERS (Sensitive data) ===
DROP POLICY IF EXISTS "Anyone can view orders" ON public.orders;

CREATE POLICY "authenticated_users_view_own_orders" ON public.orders
  FOR SELECT TO authenticated
  USING (
    customer_id = auth.uid() OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()) OR
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo'))
  );

-- === PRODUCTS (Public read for marketplace) ===
DROP POLICY IF EXISTS "Anyone can view products" ON public.products;

CREATE POLICY "public_view_active_products" ON public.products
  FOR SELECT
  USING (is_active = true);

CREATE POLICY "vendors_manage_own_products" ON public.products
  FOR ALL TO authenticated
  USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()) OR
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo'))
  )
  WITH CHECK (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()) OR
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo'))
  );

-- === Security helper function ===
CREATE OR REPLACE FUNCTION public.is_admin_or_ceo()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles 
    WHERE id = auth.uid() 
    AND role IN ('admin', 'ceo')
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_admin_or_ceo() TO authenticated;