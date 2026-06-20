-- =============================================
-- SECURITY HARDENING: Fix anonymous policies
-- Only targets tables that exist in the database
-- =============================================

-- Helper function to check if user owns a resource
CREATE OR REPLACE FUNCTION public.is_owner(resource_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT (select auth.uid()) = resource_user_id
$$;

GRANT EXECUTE ON FUNCTION public.is_owner(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.is_owner(uuid) FROM anon, public;

-- api_keys: sensitive
DROP POLICY IF EXISTS "Users can delete their own API keys" ON public.api_keys;
DROP POLICY IF EXISTS "Users can update their own API keys" ON public.api_keys;
DROP POLICY IF EXISTS "Users can view their own API keys" ON public.api_keys;

CREATE POLICY "Users can delete their own API keys" ON public.api_keys
  FOR DELETE TO authenticated USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can update their own API keys" ON public.api_keys
  FOR UPDATE TO authenticated USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can view their own API keys" ON public.api_keys
  FOR SELECT TO authenticated USING ((select auth.uid()) = user_id);

-- api_usage: sensitive
DROP POLICY IF EXISTS "Users can view their API usage" ON public.api_usage;
CREATE POLICY "Users can view their API usage" ON public.api_usage
  FOR SELECT TO authenticated 
  USING (api_key_id IN (SELECT id FROM public.api_keys WHERE user_id = (select auth.uid())));

-- wallets: very sensitive
DROP POLICY IF EXISTS "Users can view own wallet" ON public.wallets;
DROP POLICY IF EXISTS "Users can update own wallet" ON public.wallets;
CREATE POLICY "Users can view own wallet" ON public.wallets
  FOR SELECT TO authenticated USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can update own wallet" ON public.wallets
  FOR UPDATE TO authenticated USING ((select auth.uid()) = user_id);

-- transactions: uses user_id column
DROP POLICY IF EXISTS "Users can view own transactions" ON public.transactions;
CREATE POLICY "Users can view own transactions" ON public.transactions
  FOR SELECT TO authenticated USING ((select auth.uid()) = user_id);

-- profiles: sensitive PII
DROP POLICY IF EXISTS "Users can view their own profile" ON public.profiles;
DROP POLICY IF EXISTS "Users can update their own profile" ON public.profiles;
CREATE POLICY "Users can view their own profile" ON public.profiles
  FOR SELECT TO authenticated USING ((select auth.uid()) = id);
CREATE POLICY "Users can update their own profile" ON public.profiles
  FOR UPDATE TO authenticated USING ((select auth.uid()) = id);

-- customers: sensitive
DROP POLICY IF EXISTS "Users can view their customer record" ON public.customers;
DROP POLICY IF EXISTS "Users can update their customer record" ON public.customers;
CREATE POLICY "Users can view their customer record" ON public.customers
  FOR SELECT TO authenticated USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can update their customer record" ON public.customers
  FOR UPDATE TO authenticated USING ((select auth.uid()) = user_id);

-- orders: sensitive
DROP POLICY IF EXISTS "Customers can view their orders" ON public.orders;
DROP POLICY IF EXISTS "Vendors can view their orders" ON public.orders;
CREATE POLICY "Customers can view their orders" ON public.orders
  FOR SELECT TO authenticated 
  USING (
    (select auth.uid()) = customer_id 
    OR vendor_id IN (SELECT id FROM public.vendors WHERE user_id = (select auth.uid()))
  );

-- messages: sensitive
DROP POLICY IF EXISTS "Users can view their messages" ON public.messages;
CREATE POLICY "Users can view their messages" ON public.messages
  FOR SELECT TO authenticated 
  USING (
    (select auth.uid()) = sender_id 
    OR conversation_id IN (
      SELECT conversation_id FROM public.conversation_participants 
      WHERE user_id = (select auth.uid())
    )
  );

-- calls: sensitive
DROP POLICY IF EXISTS "Users can manage calls where they are caller or receiver" ON public.calls;
CREATE POLICY "Users can manage calls" ON public.calls
  FOR ALL TO authenticated 
  USING ((select auth.uid()) = caller_id OR (select auth.uid()) = receiver_id)
  WITH CHECK ((select auth.uid()) = caller_id OR (select auth.uid()) = receiver_id);

-- carts: user data
DROP POLICY IF EXISTS "Users can manage their cart" ON public.carts;
CREATE POLICY "Users can manage their cart" ON public.carts
  FOR ALL TO authenticated 
  USING ((select auth.uid()) IN (SELECT user_id FROM public.customers WHERE id = customer_id))
  WITH CHECK ((select auth.uid()) IN (SELECT user_id FROM public.customers WHERE id = customer_id));

-- notifications: user data
DROP POLICY IF EXISTS "Users can view their notifications" ON public.notifications;
DROP POLICY IF EXISTS "Users can update their notifications" ON public.notifications;
CREATE POLICY "Users can view their notifications" ON public.notifications
  FOR SELECT TO authenticated USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can update their notifications" ON public.notifications
  FOR UPDATE TO authenticated USING ((select auth.uid()) = user_id);

-- virtual_cards: very sensitive
DROP POLICY IF EXISTS "Users can view own cards" ON public.virtual_cards;
CREATE POLICY "Users can view own cards" ON public.virtual_cards
  FOR SELECT TO authenticated USING ((select auth.uid()) = user_id);

-- Create security summary view
CREATE OR REPLACE VIEW public.security_policy_summary AS
SELECT 
  schemaname,
  tablename,
  COUNT(*) as policy_count,
  COUNT(*) FILTER (WHERE roles::text LIKE '%anon%') as anon_policies,
  COUNT(*) FILTER (WHERE roles::text LIKE '%authenticated%') as auth_policies
FROM pg_policies
WHERE schemaname = 'public'
GROUP BY schemaname, tablename
ORDER BY anon_policies DESC;

COMMENT ON VIEW public.security_policy_summary IS 'Security summary. Note: spatial_ref_sys is a PostGIS system table that cannot have RLS modified.';