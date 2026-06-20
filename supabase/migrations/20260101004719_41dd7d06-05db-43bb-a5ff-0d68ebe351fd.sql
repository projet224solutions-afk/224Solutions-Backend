
-- ============================================================
-- CORRECTION APPROFONDIE DE SÉCURITÉ (sans spatial_ref_sys)
-- ============================================================

-- 2. DELIVERIES: Supprimer TOUTES les politiques et recréer proprement
DROP POLICY IF EXISTS "Customers can view their deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "Customers view own deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "Drivers can accept available deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "Drivers can view available and assigned deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "Drivers view assigned deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "PDG view all deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "System create deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "Users can manage their deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "Users can view relevant deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "Vendors can view deliveries for their orders" ON public.deliveries;
DROP POLICY IF EXISTS "Vendors view own deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "users_own_deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "deliveries_select_policy" ON public.deliveries;
DROP POLICY IF EXISTS "deliveries_insert_policy" ON public.deliveries;
DROP POLICY IF EXISTS "deliveries_update_policy" ON public.deliveries;
DROP POLICY IF EXISTS "deliveries_select" ON public.deliveries;
DROP POLICY IF EXISTS "deliveries_insert" ON public.deliveries;
DROP POLICY IF EXISTS "deliveries_modify" ON public.deliveries;

-- Nouvelles politiques deliveries (3 seulement)
CREATE POLICY "deliveries_select" ON public.deliveries
  FOR SELECT TO authenticated
  USING (
    driver_id = auth.uid() OR
    client_id = auth.uid() OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "deliveries_insert" ON public.deliveries
  FOR INSERT TO authenticated
  WITH CHECK (
    client_id = auth.uid() OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "deliveries_modify" ON public.deliveries
  FOR UPDATE TO authenticated
  USING (
    driver_id = auth.uid() OR
    client_id = auth.uid() OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

-- 3. PROFILES: Nettoyer TOUTES les politiques et recréer
DROP POLICY IF EXISTS "Admins can delete profiles" ON public.profiles;
DROP POLICY IF EXISTS "Admins can insert profiles" ON public.profiles;
DROP POLICY IF EXISTS "Admins can select all profiles" ON public.profiles;
DROP POLICY IF EXISTS "Admins can update all profiles" ON public.profiles;
DROP POLICY IF EXISTS "Admins can view all profiles" ON public.profiles;
DROP POLICY IF EXISTS "Allow public read of basic profile info for stats" ON public.profiles;
DROP POLICY IF EXISTS "Service role can insert profiles" ON public.profiles;
DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
DROP POLICY IF EXISTS "Users can update their own profile" ON public.profiles;
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
DROP POLICY IF EXISTS "Users can view their own profile" ON public.profiles;
DROP POLICY IF EXISTS "authenticated_users_view_profiles" ON public.profiles;
DROP POLICY IF EXISTS "service_role_can_insert_profiles" ON public.profiles;
DROP POLICY IF EXISTS "profiles_select_own" ON public.profiles;
DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
DROP POLICY IF EXISTS "profiles_insert_own" ON public.profiles;
DROP POLICY IF EXISTS "profiles_select" ON public.profiles;
DROP POLICY IF EXISTS "profiles_insert" ON public.profiles;
DROP POLICY IF EXISTS "profiles_update" ON public.profiles;
DROP POLICY IF EXISTS "profiles_service_insert" ON public.profiles;

-- Nouvelles politiques profiles (4 seulement)
CREATE POLICY "profiles_select" ON public.profiles
  FOR SELECT TO authenticated
  USING (id = auth.uid());

CREATE POLICY "profiles_insert" ON public.profiles
  FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid());

CREATE POLICY "profiles_update" ON public.profiles
  FOR UPDATE TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- Service role pour création profil à l'inscription
CREATE POLICY "profiles_service_insert" ON public.profiles
  FOR INSERT TO service_role
  WITH CHECK (true);

-- 4. PRODUCTS: Supprimer politique anon
DROP POLICY IF EXISTS "Anon can read vendor products" ON public.products;

-- 5. BUG_BOUNTY_HALL_OF_FAME: Remplacer par authenticated uniquement
DROP POLICY IF EXISTS "Anyone can view hall of fame" ON public.bug_bounty_hall_of_fame;
DROP POLICY IF EXISTS "hall_of_fame_public_read" ON public.bug_bounty_hall_of_fame;

CREATE POLICY "hall_of_fame_read" ON public.bug_bounty_hall_of_fame
  FOR SELECT TO authenticated
  USING (true);
