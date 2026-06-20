-- Batch 4f: Continue fixing more tables - bureaus, calls, carts, categories, clients

-- bureaus
DROP POLICY IF EXISTS "Admins view all bureaus" ON public.bureaus;
DROP POLICY IF EXISTS "Anyone can view bureau with valid access_token" ON public.bureaus;
DROP POLICY IF EXISTS "Bureau update own data" ON public.bureaus;
DROP POLICY IF EXISTS "Bureau view own data" ON public.bureaus;
DROP POLICY IF EXISTS "PDG manage all bureaus" ON public.bureaus;
DROP POLICY IF EXISTS "users_own_bureaus" ON public.bureaus;
CREATE POLICY "users_own_bureaus" ON public.bureaus
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
CREATE POLICY "admins_view_all_bureaus" ON public.bureaus
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));
CREATE POLICY "pdg_manage_all_bureaus" ON public.bureaus
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.pdg_management pdg WHERE pdg.user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.pdg_management pdg WHERE pdg.user_id = auth.uid()));

-- calls
DROP POLICY IF EXISTS "Users manage own calls" ON public.calls;
DROP POLICY IF EXISTS "users_own_calls" ON public.calls;
CREATE POLICY "users_own_calls" ON public.calls
  FOR ALL TO authenticated
  USING (caller_id = auth.uid() OR receiver_id = auth.uid())
  WITH CHECK (caller_id = auth.uid());

-- card_transactions
DROP POLICY IF EXISTS "Users can view their own card transactions" ON public.card_transactions;
CREATE POLICY "users_view_own_card_transactions" ON public.card_transactions
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- carts
DROP POLICY IF EXISTS "Users manage own cart" ON public.carts;
DROP POLICY IF EXISTS "customers_own_carts" ON public.carts;
CREATE POLICY "customers_own_carts" ON public.carts
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.customers c WHERE c.id = carts.customer_id AND c.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.customers c WHERE c.id = carts.customer_id AND c.user_id = auth.uid()
  ));

-- categories
DROP POLICY IF EXISTS "Admins manage categories" ON public.categories;
DROP POLICY IF EXISTS "Everyone view active categories" ON public.categories;
DROP POLICY IF EXISTS "authenticated_read_categories" ON public.categories;
CREATE POLICY "authenticated_read_categories" ON public.categories
  FOR SELECT TO authenticated
  USING (is_active = true);
CREATE POLICY "admins_manage_categories" ON public.categories
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- clients
DROP POLICY IF EXISTS "Vendors manage own clients" ON public.clients;
CREATE POLICY "vendors_manage_own_clients" ON public.clients
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.vendors v WHERE v.id = clients.vendor_id AND v.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.vendors v WHERE v.id = clients.vendor_id AND v.user_id = auth.uid()
  ));

-- commission_config
DROP POLICY IF EXISTS "PDG manage commission config" ON public.commission_config;
DROP POLICY IF EXISTS "users_view_commission_config" ON public.commission_config;
CREATE POLICY "users_view_commission_config" ON public.commission_config
  FOR SELECT TO authenticated
  USING (is_active = true);
CREATE POLICY "pdg_manage_commission_config" ON public.commission_config
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.pdg_management pdg WHERE pdg.user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.pdg_management pdg WHERE pdg.user_id = auth.uid()));

-- communication_audit_logs
DROP POLICY IF EXISTS "Users view own audit logs" ON public.communication_audit_logs;
CREATE POLICY "users_view_own_audit_logs" ON public.communication_audit_logs
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- communication_notifications
DROP POLICY IF EXISTS "Users manage own notifications" ON public.communication_notifications;
CREATE POLICY "users_manage_own_notifications" ON public.communication_notifications
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- compliance_audits
DROP POLICY IF EXISTS "Admins manage compliance audits" ON public.compliance_audits;
CREATE POLICY "admins_manage_compliance_audits" ON public.compliance_audits
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- contracts
DROP POLICY IF EXISTS "Admins view all contracts" ON public.contracts;
DROP POLICY IF EXISTS "Clients view own contracts" ON public.contracts;
DROP POLICY IF EXISTS "Vendors manage own contracts" ON public.contracts;
CREATE POLICY "vendors_manage_own_contracts" ON public.contracts
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.vendors v WHERE v.id = contracts.vendor_id AND v.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.vendors v WHERE v.id = contracts.vendor_id AND v.user_id = auth.uid()
  ));
CREATE POLICY "admins_view_all_contracts" ON public.contracts
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- conversation_participants
DROP POLICY IF EXISTS "Users view conversation participants" ON public.conversation_participants;
CREATE POLICY "users_view_conversation_participants" ON public.conversation_participants
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR EXISTS (
    SELECT 1 FROM public.conversation_participants cp2 
    WHERE cp2.conversation_id = conversation_participants.conversation_id AND cp2.user_id = auth.uid()
  ));

-- conversations
DROP POLICY IF EXISTS "Creators update own conversations" ON public.conversations;
DROP POLICY IF EXISTS "Users view own conversations" ON public.conversations;
CREATE POLICY "users_view_own_conversations" ON public.conversations
  FOR SELECT TO authenticated
  USING (creator_id = auth.uid() OR EXISTS (
    SELECT 1 FROM public.conversation_participants cp WHERE cp.conversation_id = conversations.id AND cp.user_id = auth.uid()
  ));
CREATE POLICY "creators_update_own_conversations" ON public.conversations
  FOR UPDATE TO authenticated
  USING (creator_id = auth.uid())
  WITH CHECK (creator_id = auth.uid());

-- copilot_conversations
DROP POLICY IF EXISTS "PDG access copilot" ON public.copilot_conversations;
DROP POLICY IF EXISTS "users_own_copilot_conversations" ON public.copilot_conversations;
CREATE POLICY "users_own_copilot_conversations" ON public.copilot_conversations
  FOR ALL TO authenticated
  USING (pdg_user_id = auth.uid())
  WITH CHECK (pdg_user_id = auth.uid());