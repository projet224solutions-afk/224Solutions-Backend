-- Fix RLS policies for service_plans: allow public read
DROP POLICY IF EXISTS "Service plans are viewable by everyone" ON service_plans;
CREATE POLICY "Service plans are viewable by everyone"
  ON service_plans FOR SELECT
  TO public
  USING (true);

DROP POLICY IF EXISTS "Only admins can modify service plans" ON service_plans;
CREATE POLICY "Authenticated users can manage service plans"
  ON service_plans FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- Fix RLS policies for service_types: ensure public read
DROP POLICY IF EXISTS "Service types are viewable by everyone" ON service_types;
CREATE POLICY "Service types are viewable by everyone"
  ON service_types FOR SELECT
  TO public
  USING (true);

-- Fix RLS policies for service_subscriptions
DROP POLICY IF EXISTS "Admins can manage all service subscriptions" ON service_subscriptions;
DROP POLICY IF EXISTS "Admins can view all service subscriptions" ON service_subscriptions;
DROP POLICY IF EXISTS "Users can insert their own service subscriptions" ON service_subscriptions;
DROP POLICY IF EXISTS "Users can view their own service subscriptions" ON service_subscriptions;

-- Users can view their own subscriptions
CREATE POLICY "Users can view own subscriptions"
  ON service_subscriptions FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- Users can insert their own subscriptions
CREATE POLICY "Users can insert own subscriptions"
  ON service_subscriptions FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

-- Users can update their own subscriptions
CREATE POLICY "Users can update own subscriptions"
  ON service_subscriptions FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Admin-level access via has_role function (if exists) or broad authenticated read for PDG
CREATE POLICY "Admins can view all subscriptions"
  ON service_subscriptions FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM pdg_management WHERE user_id = auth.uid()
    )
  );

-- Admins can manage all subscriptions
CREATE POLICY "Admins can manage all subscriptions"
  ON service_subscriptions FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM pdg_management WHERE user_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM pdg_management WHERE user_id = auth.uid()
    )
  );