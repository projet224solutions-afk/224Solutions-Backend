-- Batch 1: Fix RLS policies for tables A-C (add TO authenticated)

-- advanced_carts
DROP POLICY IF EXISTS "authenticated_users_manage_own_cart" ON public.advanced_carts;
CREATE POLICY "authenticated_users_manage_own_cart" ON public.advanced_carts
  FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- agent_commissions_log
DROP POLICY IF EXISTS "Agents can view own commission logs" ON public.agent_commissions_log;
CREATE POLICY "Agents can view own commission logs" ON public.agent_commissions_log
  FOR SELECT TO authenticated USING (
    agent_id IN (SELECT id FROM agents_management WHERE user_id = auth.uid())
  );

DROP POLICY IF EXISTS "PDG can view all commission logs" ON public.agent_commissions_log;
CREATE POLICY "PDG can view all commission logs" ON public.agent_commissions_log
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- agent_created_users
DROP POLICY IF EXISTS "Agents can view sub-agents created users" ON public.agent_created_users;
CREATE POLICY "Agents can view sub-agents created users" ON public.agent_created_users
  FOR SELECT TO authenticated USING (
    agent_id IN (SELECT id FROM agents_management WHERE user_id = auth.uid())
  );

DROP POLICY IF EXISTS "PDG can view all agent_created_users" ON public.agent_created_users;
CREATE POLICY "PDG can view all agent_created_users" ON public.agent_created_users
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

DROP POLICY IF EXISTS "agents_view_created_users" ON public.agent_created_users;
CREATE POLICY "agents_view_created_users" ON public.agent_created_users
  FOR SELECT TO authenticated USING (
    agent_id IN (SELECT id FROM agents_management WHERE user_id = auth.uid())
  );

-- agent_invitations
DROP POLICY IF EXISTS "Agents can view their own invitations" ON public.agent_invitations;
CREATE POLICY "Agents can view their own invitations" ON public.agent_invitations
  FOR SELECT TO authenticated USING (
    agent_id IN (SELECT id FROM agents_management WHERE user_id = auth.uid())
  );

DROP POLICY IF EXISTS "PDG can manage their agent invitations" ON public.agent_invitations;
CREATE POLICY "PDG can manage their agent invitations" ON public.agent_invitations
  FOR ALL TO authenticated USING (
    pdg_id IN (SELECT id FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    pdg_id IN (SELECT id FROM pdg_management WHERE user_id = auth.uid())
  );

-- agent_permissions
DROP POLICY IF EXISTS "Agent can view own permissions" ON public.agent_permissions;
CREATE POLICY "Agent can view own permissions" ON public.agent_permissions
  FOR SELECT TO authenticated USING (
    agent_id IN (SELECT id FROM agents_management WHERE user_id = auth.uid())
  );

DROP POLICY IF EXISTS "PDG can manage agent permissions" ON public.agent_permissions;
CREATE POLICY "PDG can manage agent permissions" ON public.agent_permissions
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- agent_wallets
DROP POLICY IF EXISTS "Agents can update own wallet balance" ON public.agent_wallets;
DROP POLICY IF EXISTS "admins_read_all_agent_wallets" ON public.agent_wallets;
DROP POLICY IF EXISTS "admins_update_all_agent_wallets" ON public.agent_wallets;
DROP POLICY IF EXISTS "agents_read_own_wallet" ON public.agent_wallets;
DROP POLICY IF EXISTS "pdg_read_agent_wallets" ON public.agent_wallets;

CREATE POLICY "agents_read_own_wallet" ON public.agent_wallets
  FOR SELECT TO authenticated USING (
    agent_id IN (SELECT id FROM agents_management WHERE user_id = auth.uid())
  );

CREATE POLICY "pdg_read_all_agent_wallets" ON public.agent_wallets
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

CREATE POLICY "pdg_manage_agent_wallets" ON public.agent_wallets
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- agents (main table)
DROP POLICY IF EXISTS "Vendors can manage their agents" ON public.agents;
CREATE POLICY "Vendors can manage their agents" ON public.agents
  FOR ALL TO authenticated USING (
    seller_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  ) WITH CHECK (
    seller_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

-- agents_management
DROP POLICY IF EXISTS "Agents can update their own profile" ON public.agents_management;
DROP POLICY IF EXISTS "Agents can view their own profile" ON public.agents_management;
DROP POLICY IF EXISTS "Agents can view their sub-agents" ON public.agents_management;
DROP POLICY IF EXISTS "Agents view own data" ON public.agents_management;
DROP POLICY IF EXISTS "PDG can manage their agents" ON public.agents_management;
DROP POLICY IF EXISTS "PDG can view agents" ON public.agents_management;
DROP POLICY IF EXISTS "PDG manage agents" ON public.agents_management;

CREATE POLICY "Agents can view own data" ON public.agents_management
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE POLICY "Agents can update own profile" ON public.agents_management
  FOR UPDATE TO authenticated USING (user_id = auth.uid());

CREATE POLICY "PDG can manage all agents" ON public.agents_management
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- ai_generated_documents
DROP POLICY IF EXISTS "Users can delete their own generated documents" ON public.ai_generated_documents;
DROP POLICY IF EXISTS "Users can view their own generated documents" ON public.ai_generated_documents;

CREATE POLICY "Users manage own ai documents" ON public.ai_generated_documents
  FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- api_alerts
DROP POLICY IF EXISTS "PDG can manage api_alerts" ON public.api_alerts;
CREATE POLICY "PDG can manage api_alerts" ON public.api_alerts
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- api_connections
DROP POLICY IF EXISTS "PDG can manage api_connections" ON public.api_connections;
CREATE POLICY "PDG can manage api_connections" ON public.api_connections
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- api_keys
DROP POLICY IF EXISTS "authenticated_users_manage_own_api_keys" ON public.api_keys;
CREATE POLICY "authenticated_users_manage_own_api_keys" ON public.api_keys
  FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- api_usage
DROP POLICY IF EXISTS "Users can view their API usage" ON public.api_usage;
CREATE POLICY "Users can view their API usage" ON public.api_usage
  FOR SELECT TO authenticated USING (
    api_key_id IN (SELECT id FROM api_keys WHERE user_id = auth.uid())
  );

-- api_usage_logs
DROP POLICY IF EXISTS "PDG can view api_usage_logs" ON public.api_usage_logs;
CREATE POLICY "PDG can view api_usage_logs" ON public.api_usage_logs
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- audit_logs
DROP POLICY IF EXISTS "authenticated_admins_view_audit_logs" ON public.audit_logs;
CREATE POLICY "authenticated_admins_view_audit_logs" ON public.audit_logs
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- auth_attempts_log
DROP POLICY IF EXISTS "admin_only_auth_attempts" ON public.auth_attempts_log;
CREATE POLICY "admin_only_auth_attempts" ON public.auth_attempts_log
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- auto_fixes
DROP POLICY IF EXISTS "admin_can_manage_fixes" ON public.auto_fixes;
CREATE POLICY "admin_can_manage_fixes" ON public.auto_fixes
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- badges
DROP POLICY IF EXISTS "Admins peuvent tout voir" ON public.badges;
DROP POLICY IF EXISTS "Bureau peut gérer ses badges" ON public.badges;

CREATE POLICY "Bureau manage own badges" ON public.badges
  FOR ALL TO authenticated USING (
    bureau_id IN (SELECT id FROM bureaus WHERE user_id = auth.uid())
  ) WITH CHECK (
    bureau_id IN (SELECT id FROM bureaus WHERE user_id = auth.uid())
  );

CREATE POLICY "Admins view all badges" ON public.badges
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- balance_reconciliation
DROP POLICY IF EXISTS "PDG full access to reconciliation" ON public.balance_reconciliation;
CREATE POLICY "PDG full access to reconciliation" ON public.balance_reconciliation
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- beauty_appointments
DROP POLICY IF EXISTS "Beauty appointments owner access" ON public.beauty_appointments;
CREATE POLICY "Beauty appointments owner access" ON public.beauty_appointments
  FOR ALL TO authenticated USING (
    professional_service_id IN (SELECT id FROM professional_services WHERE user_id = auth.uid())
  ) WITH CHECK (
    professional_service_id IN (SELECT id FROM professional_services WHERE user_id = auth.uid())
  );

-- beauty_services
DROP POLICY IF EXISTS "Beauty services owner access" ON public.beauty_services;
CREATE POLICY "Beauty services owner access" ON public.beauty_services
  FOR ALL TO authenticated USING (
    professional_service_id IN (SELECT id FROM professional_services WHERE user_id = auth.uid())
  ) WITH CHECK (
    professional_service_id IN (SELECT id FROM professional_services WHERE user_id = auth.uid())
  );

-- beauty_staff
DROP POLICY IF EXISTS "Beauty staff owner access" ON public.beauty_staff;
CREATE POLICY "Beauty staff owner access" ON public.beauty_staff
  FOR ALL TO authenticated USING (
    professional_service_id IN (SELECT id FROM professional_services WHERE user_id = auth.uid())
  ) WITH CHECK (
    professional_service_id IN (SELECT id FROM professional_services WHERE user_id = auth.uid())
  );

-- blocked_ips
DROP POLICY IF EXISTS "Admins blocked ips" ON public.blocked_ips;
DROP POLICY IF EXISTS "Admins can delete blocked ips" ON public.blocked_ips;
DROP POLICY IF EXISTS "Admins can manage blocked IPs" ON public.blocked_ips;
DROP POLICY IF EXISTS "Admins can read blocked ips" ON public.blocked_ips;
DROP POLICY IF EXISTS "Admins can update blocked ips" ON public.blocked_ips;

CREATE POLICY "Admins manage blocked ips" ON public.blocked_ips
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- bug_bounty_hall_of_fame
DROP POLICY IF EXISTS "Admins can manage hall of fame" ON public.bug_bounty_hall_of_fame;
CREATE POLICY "Admins can manage hall of fame" ON public.bug_bounty_hall_of_fame
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- bug_bounty_rewards
DROP POLICY IF EXISTS "Admins can manage rewards" ON public.bug_bounty_rewards;
CREATE POLICY "Admins can manage rewards" ON public.bug_bounty_rewards
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- bug_reports
DROP POLICY IF EXISTS "Admins can update bug reports" ON public.bug_reports;
DROP POLICY IF EXISTS "Admins can view all bug reports" ON public.bug_reports;

CREATE POLICY "Admins manage bug reports" ON public.bug_reports
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- bureau_access_logs
DROP POLICY IF EXISTS "Admins peuvent voir les logs" ON public.bureau_access_logs;

CREATE POLICY "Admins view bureau access logs" ON public.bureau_access_logs
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
    OR bureau_id IN (SELECT id FROM bureaus WHERE user_id = auth.uid())
  );

-- bureau_feature_assignments
DROP POLICY IF EXISTS "Admins can manage feature assignments" ON public.bureau_feature_assignments;
DROP POLICY IF EXISTS "Bureau presidents can view their assignments" ON public.bureau_feature_assignments;

CREATE POLICY "Admins manage feature assignments" ON public.bureau_feature_assignments
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

CREATE POLICY "Bureau view own assignments" ON public.bureau_feature_assignments
  FOR SELECT TO authenticated USING (
    bureau_id IN (SELECT id FROM bureaus WHERE user_id = auth.uid())
  );

-- bureau_features
DROP POLICY IF EXISTS "Everyone can view active features" ON public.bureau_features;
DROP POLICY IF EXISTS "PDG and Admins manage features v2" ON public.bureau_features;

CREATE POLICY "Authenticated view active features" ON public.bureau_features
  FOR SELECT TO authenticated USING (is_active = true);

CREATE POLICY "Admins manage features" ON public.bureau_features
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- bureau_transactions
DROP POLICY IF EXISTS "service_role_all" ON public.bureau_transactions;

CREATE POLICY "Bureau view own transactions" ON public.bureau_transactions
  FOR SELECT TO authenticated USING (
    bureau_id IN (SELECT id FROM bureaus WHERE user_id = auth.uid())
  );

CREATE POLICY "PDG manage bureau transactions" ON public.bureau_transactions
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- bureau_wallets
DROP POLICY IF EXISTS "Admins can manage bureau wallets" ON public.bureau_wallets;
DROP POLICY IF EXISTS "Allow authenticated users to update bureau_wallets" ON public.bureau_wallets;
DROP POLICY IF EXISTS "Bureau members can view bureau wallet" ON public.bureau_wallets;
DROP POLICY IF EXISTS "Bureaus can view their own wallet" ON public.bureau_wallets;
DROP POLICY IF EXISTS "PDG manage wallets" ON public.bureau_wallets;
DROP POLICY IF EXISTS "PDG view all wallets" ON public.bureau_wallets;
DROP POLICY IF EXISTS "Service role full access to bureau_wallets" ON public.bureau_wallets;
DROP POLICY IF EXISTS "Service role manage wallets" ON public.bureau_wallets;

CREATE POLICY "Bureau view own wallet" ON public.bureau_wallets
  FOR SELECT TO authenticated USING (
    bureau_id IN (SELECT id FROM bureaus WHERE user_id = auth.uid())
  );

CREATE POLICY "PDG manage all bureau wallets" ON public.bureau_wallets
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- bureaus
DROP POLICY IF EXISTS "Admins can delete bureaus" ON public.bureaus;
DROP POLICY IF EXISTS "Admins can update bureaus" ON public.bureaus;
DROP POLICY IF EXISTS "Admins can view all bureaus" ON public.bureaus;
DROP POLICY IF EXISTS "PDG manage bureaus" ON public.bureaus;
DROP POLICY IF EXISTS "PDG view all bureaus" ON public.bureaus;

CREATE POLICY "Bureau view own data" ON public.bureaus
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE POLICY "Bureau update own data" ON public.bureaus
  FOR UPDATE TO authenticated USING (user_id = auth.uid());

CREATE POLICY "PDG manage all bureaus" ON public.bureaus
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

CREATE POLICY "Admins view all bureaus" ON public.bureaus
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- calls (caller_id and receiver_id are UUID)
DROP POLICY IF EXISTS "Users can manage calls" ON public.calls;

CREATE POLICY "Users manage own calls" ON public.calls
  FOR ALL TO authenticated USING (
    caller_id = auth.uid() OR receiver_id = auth.uid()
  ) WITH CHECK (
    caller_id = auth.uid() OR receiver_id = auth.uid()
  );

-- carts
DROP POLICY IF EXISTS "Users can manage their cart" ON public.carts;

CREATE POLICY "Users manage own cart" ON public.carts
  FOR ALL TO authenticated USING (
    customer_id IN (SELECT id FROM customers WHERE user_id = auth.uid())
  ) WITH CHECK (
    customer_id IN (SELECT id FROM customers WHERE user_id = auth.uid())
  );

-- categories (keep public read for marketplace)
DROP POLICY IF EXISTS "Admins and vendors can manage categories" ON public.categories;
DROP POLICY IF EXISTS "Everyone can view active categories" ON public.categories;

CREATE POLICY "Everyone view active categories" ON public.categories
  FOR SELECT USING (is_active = true);

CREATE POLICY "Admins manage categories" ON public.categories
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM vendors WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM vendors WHERE user_id = auth.uid())
  );

-- clients
DROP POLICY IF EXISTS "Vendeurs peuvent modifier leurs clients" ON public.clients;
DROP POLICY IF EXISTS "Vendeurs peuvent supprimer leurs clients" ON public.clients;
DROP POLICY IF EXISTS "Vendeurs peuvent voir leurs clients" ON public.clients;

CREATE POLICY "Vendors manage own clients" ON public.clients
  FOR ALL TO authenticated USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  ) WITH CHECK (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

-- commission_config
DROP POLICY IF EXISTS "PDG only access commission_config" ON public.commission_config;

CREATE POLICY "PDG manage commission config" ON public.commission_config
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- communication_audit_logs
DROP POLICY IF EXISTS "Users can view their own audit logs" ON public.communication_audit_logs;
CREATE POLICY "Users view own audit logs" ON public.communication_audit_logs
  FOR SELECT TO authenticated USING (user_id = auth.uid());

-- communication_notifications
DROP POLICY IF EXISTS "Users can update their own notifications" ON public.communication_notifications;
DROP POLICY IF EXISTS "Users can view their own notifications" ON public.communication_notifications;

CREATE POLICY "Users manage own notifications" ON public.communication_notifications
  FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- compliance_audits
DROP POLICY IF EXISTS "Admins can manage compliance audits" ON public.compliance_audits;
CREATE POLICY "Admins manage compliance audits" ON public.compliance_audits
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
    OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- contracts
DROP POLICY IF EXISTS "Admin can view all contracts" ON public.contracts;
DROP POLICY IF EXISTS "Clients can update signature on their contracts" ON public.contracts;
DROP POLICY IF EXISTS "Clients can view their contracts" ON public.contracts;
DROP POLICY IF EXISTS "Vendors can update their own contracts" ON public.contracts;
DROP POLICY IF EXISTS "Vendors can view their own contracts" ON public.contracts;

CREATE POLICY "Vendors manage own contracts" ON public.contracts
  FOR ALL TO authenticated USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  ) WITH CHECK (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Clients view own contracts" ON public.contracts
  FOR SELECT TO authenticated USING (
    client_id = auth.uid()
  );

CREATE POLICY "Admins view all contracts" ON public.contracts
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- conversation_participants
DROP POLICY IF EXISTS "Service role full access to participants" ON public.conversation_participants;
DROP POLICY IF EXISTS "Users can view participants of their conversations" ON public.conversation_participants;

CREATE POLICY "Users view conversation participants" ON public.conversation_participants
  FOR SELECT TO authenticated USING (
    conversation_id IN (
      SELECT conversation_id FROM conversation_participants WHERE user_id = auth.uid()
    )
  );

-- conversations (use creator_id not created_by)
DROP POLICY IF EXISTS "Creators can update their conversations" ON public.conversations;
DROP POLICY IF EXISTS "Participants can view conversations" ON public.conversations;
DROP POLICY IF EXISTS "Service role full access to conversations" ON public.conversations;
DROP POLICY IF EXISTS "Users can view conversations they participate in" ON public.conversations;

CREATE POLICY "Users view own conversations" ON public.conversations
  FOR SELECT TO authenticated USING (
    id IN (SELECT conversation_id FROM conversation_participants WHERE user_id = auth.uid())
    OR creator_id = auth.uid()
  );

CREATE POLICY "Creators update own conversations" ON public.conversations
  FOR UPDATE TO authenticated USING (creator_id = auth.uid());

-- copilot_conversations
DROP POLICY IF EXISTS "PDG only access copilot" ON public.copilot_conversations;

CREATE POLICY "PDG access copilot" ON public.copilot_conversations
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
  );

-- currencies (keep public read)
DROP POLICY IF EXISTS "currencies_admin_delete" ON public.currencies;
DROP POLICY IF EXISTS "currencies_admin_update" ON public.currencies;
DROP POLICY IF EXISTS "currencies_select" ON public.currencies;

CREATE POLICY "Everyone read currencies" ON public.currencies
  FOR SELECT USING (true);

CREATE POLICY "Admins manage currencies" ON public.currencies
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- custom_report_templates
DROP POLICY IF EXISTS "Users can delete their own report templates" ON public.custom_report_templates;
DROP POLICY IF EXISTS "Users can update their own report templates" ON public.custom_report_templates;
DROP POLICY IF EXISTS "Users can view their own report templates" ON public.custom_report_templates;

CREATE POLICY "Users manage own report templates" ON public.custom_report_templates
  FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- customer_credits
DROP POLICY IF EXISTS "Vendors can manage their customer credits" ON public.customer_credits;

CREATE POLICY "Vendors manage customer credits" ON public.customer_credits
  FOR ALL TO authenticated USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  ) WITH CHECK (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

-- customers
DROP POLICY IF EXISTS "Admins can view all customers" ON public.customers;
DROP POLICY IF EXISTS "Users can manage their customer profile" ON public.customers;
DROP POLICY IF EXISTS "Users can update their customer record" ON public.customers;
DROP POLICY IF EXISTS "Users can view their customer record" ON public.customers;
DROP POLICY IF EXISTS "Vendors can view their customers through orders" ON public.customers;

CREATE POLICY "Users manage own customer profile" ON public.customers
  FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

CREATE POLICY "Admins view all customers" ON public.customers
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "Vendors view own customers" ON public.customers
  FOR SELECT TO authenticated USING (
    id IN (SELECT DISTINCT customer_id FROM orders WHERE vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()))
  );