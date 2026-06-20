-- ============================================
-- COMPREHENSIVE SECURITY HARDENING (CORRECTED v3)
-- Fix all critical security vulnerabilities
-- ============================================

-- 1. Enable RLS on id_counters table and restrict access to service_role only
ALTER TABLE IF EXISTS public.id_counters ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role only access" ON public.id_counters;
CREATE POLICY "Service role only access" ON public.id_counters
  FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- 2. Fix agents_management - restrict sensitive data access
DROP POLICY IF EXISTS "PDG can view agents" ON public.agents_management;
DROP POLICY IF EXISTS "Agents view own data" ON public.agents_management;
DROP POLICY IF EXISTS "PDG manage agents" ON public.agents_management;

-- Only PDG can view their agents
CREATE POLICY "PDG can view agents" ON public.agents_management
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.pdg_management pdg
      WHERE pdg.id = agents_management.pdg_id
      AND pdg.user_id = (SELECT auth.uid())
    )
  );

-- Agents can view their own data only
CREATE POLICY "Agents view own data" ON public.agents_management
  FOR SELECT
  USING (user_id = (SELECT auth.uid()));

-- PDG can manage their agents (INSERT, UPDATE, DELETE)
CREATE POLICY "PDG manage agents" ON public.agents_management
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.pdg_management pdg
      WHERE pdg.id = agents_management.pdg_id
      AND pdg.user_id = (SELECT auth.uid())
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.pdg_management pdg
      WHERE pdg.id = agents_management.pdg_id
      AND pdg.user_id = (SELECT auth.uid())
    )
  );

-- 3. Fix bureaus - restrict president contact information
DROP POLICY IF EXISTS "PDG view all bureaus" ON public.bureaus;
DROP POLICY IF EXISTS "PDG manage bureaus" ON public.bureaus;

-- Only PDG can view all bureau details including president contacts
CREATE POLICY "PDG view all bureaus" ON public.bureaus
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.pdg_management
      WHERE user_id = (SELECT auth.uid())
    )
  );

-- PDG can manage all bureaus
CREATE POLICY "PDG manage bureaus" ON public.bureaus
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.pdg_management
      WHERE user_id = (SELECT auth.uid())
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.pdg_management
      WHERE user_id = (SELECT auth.uid())
    )
  );

-- 4. Fix syndicate_workers - restrict personal information
DROP POLICY IF EXISTS "PDG view all workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "PDG manage workers" ON public.syndicate_workers;

-- Only PDG can view all workers
CREATE POLICY "PDG view all workers" ON public.syndicate_workers
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.pdg_management
      WHERE user_id = (SELECT auth.uid())
    )
  );

-- PDG can manage all workers
CREATE POLICY "PDG manage workers" ON public.syndicate_workers
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.pdg_management
      WHERE user_id = (SELECT auth.uid())
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.pdg_management
      WHERE user_id = (SELECT auth.uid())
    )
  );

-- 5. Fix deliveries - restrict address information
DROP POLICY IF EXISTS "Drivers view assigned deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "Customers view own deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "Vendors view own deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "PDG view all deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "System create deliveries" ON public.deliveries;
DROP POLICY IF EXISTS "Drivers update deliveries" ON public.deliveries;

-- Assigned driver can view their deliveries (using correct enum values)
CREATE POLICY "Drivers view assigned deliveries" ON public.deliveries
  FOR SELECT
  USING (
    driver_id = (SELECT auth.uid())
    AND status IN ('assigned', 'picked_up', 'in_transit', 'delivered')
  );

-- Customer can view their deliveries (through order)
CREATE POLICY "Customers view own deliveries" ON public.deliveries
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = deliveries.order_id
      AND o.customer_id = (SELECT auth.uid())
    )
  );

-- Vendor can view deliveries for their orders
CREATE POLICY "Vendors view own deliveries" ON public.deliveries
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.orders o
      JOIN public.vendors v ON v.id = o.vendor_id
      WHERE o.id = deliveries.order_id
      AND v.user_id = (SELECT auth.uid())
    )
  );

-- PDG can view all deliveries
CREATE POLICY "PDG view all deliveries" ON public.deliveries
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.pdg_management
      WHERE user_id = (SELECT auth.uid())
    )
  );

-- System can create deliveries
CREATE POLICY "System create deliveries" ON public.deliveries
  FOR INSERT
  WITH CHECK (auth.role() IN ('authenticated', 'service_role'));

-- Drivers can update their assigned deliveries
CREATE POLICY "Drivers update deliveries" ON public.deliveries
  FOR UPDATE
  USING (driver_id = (SELECT auth.uid()))
  WITH CHECK (driver_id = (SELECT auth.uid()));

-- 6. Fix bureau_wallets - restrict balance information
DROP POLICY IF EXISTS "PDG view all wallets" ON public.bureau_wallets;
DROP POLICY IF EXISTS "Service role manage wallets" ON public.bureau_wallets;
DROP POLICY IF EXISTS "PDG manage wallets" ON public.bureau_wallets;

-- Only PDG can view all wallets
CREATE POLICY "PDG view all wallets" ON public.bureau_wallets
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.pdg_management
      WHERE user_id = (SELECT auth.uid())
    )
  );

-- Service role can manage wallets for transactions
CREATE POLICY "Service role manage wallets" ON public.bureau_wallets
  FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- PDG can manage all wallets
CREATE POLICY "PDG manage wallets" ON public.bureau_wallets
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.pdg_management
      WHERE user_id = (SELECT auth.uid())
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.pdg_management
      WHERE user_id = (SELECT auth.uid())
    )
  );