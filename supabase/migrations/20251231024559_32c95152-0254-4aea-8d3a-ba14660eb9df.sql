-- ===========================================
-- SECURITY FIXES BATCH 3 - Fix Anonymous Access Policies (Part 1 - Critical Tables)
-- ===========================================

-- agent_created_users
DROP POLICY IF EXISTS "Agents can view sub-agents created users" ON public.agent_created_users;
CREATE POLICY "Agents can view sub-agents created users" ON public.agent_created_users
FOR SELECT TO authenticated
USING (auth.uid() IN (SELECT user_id FROM public.agents_management WHERE id = agent_id OR parent_agent_id = agent_id));

DROP POLICY IF EXISTS "PDG can view all agent_created_users" ON public.agent_created_users;
CREATE POLICY "PDG can view all agent_created_users" ON public.agent_created_users
FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- agent_invitations
DROP POLICY IF EXISTS "Agents can view their own invitations" ON public.agent_invitations;
CREATE POLICY "Agents can view their own invitations" ON public.agent_invitations
FOR SELECT TO authenticated
USING (agent_id IN (SELECT id FROM public.agents_management WHERE user_id = auth.uid()));

DROP POLICY IF EXISTS "PDG can manage their agent invitations" ON public.agent_invitations;
CREATE POLICY "PDG can manage their agent invitations" ON public.agent_invitations
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- agent_permissions
DROP POLICY IF EXISTS "PDG can manage agent permissions" ON public.agent_permissions;
CREATE POLICY "PDG can manage agent permissions" ON public.agent_permissions
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- agent_wallets (financial data - critical)
DROP POLICY IF EXISTS "admins_read_all_agent_wallets" ON public.agent_wallets;
CREATE POLICY "admins_read_all_agent_wallets" ON public.agent_wallets
FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "admins_update_all_agent_wallets" ON public.agent_wallets;
CREATE POLICY "admins_update_all_agent_wallets" ON public.agent_wallets
FOR UPDATE TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "admins_insert_agent_wallets" ON public.agent_wallets;
CREATE POLICY "admins_insert_agent_wallets" ON public.agent_wallets
FOR INSERT TO authenticated
WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "pdg_read_agent_wallets" ON public.agent_wallets;
CREATE POLICY "pdg_read_agent_wallets" ON public.agent_wallets
FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "pdg_insert_agent_wallets" ON public.agent_wallets;
CREATE POLICY "pdg_insert_agent_wallets" ON public.agent_wallets
FOR INSERT TO authenticated
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- agents
DROP POLICY IF EXISTS "Vendors can manage their agents" ON public.agents;
CREATE POLICY "Vendors can manage their agents" ON public.agents
FOR ALL TO authenticated
USING (seller_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()))
WITH CHECK (seller_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()));

-- agents_management
DROP POLICY IF EXISTS "Agents can view their own profile" ON public.agents_management;
CREATE POLICY "Agents can view their own profile" ON public.agents_management
FOR SELECT TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Agents view own data" ON public.agents_management;
CREATE POLICY "Agents view own data" ON public.agents_management
FOR SELECT TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "PDG can manage their agents" ON public.agents_management;
CREATE POLICY "PDG can manage their agents" ON public.agents_management
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "PDG can view agents" ON public.agents_management;
CREATE POLICY "PDG can view agents" ON public.agents_management
FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "PDG manage agents" ON public.agents_management;
CREATE POLICY "PDG manage agents" ON public.agents_management
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- ai_generated_documents
DROP POLICY IF EXISTS "Users can delete their own generated documents" ON public.ai_generated_documents;
CREATE POLICY "Users can delete their own generated documents" ON public.ai_generated_documents
FOR DELETE TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can view their own generated documents" ON public.ai_generated_documents;
CREATE POLICY "Users can view their own generated documents" ON public.ai_generated_documents
FOR SELECT TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "System can insert generated documents" ON public.ai_generated_documents;
CREATE POLICY "System can insert generated documents" ON public.ai_generated_documents
FOR INSERT TO authenticated
WITH CHECK (user_id = auth.uid());

-- api_alerts
DROP POLICY IF EXISTS "PDG can manage api_alerts" ON public.api_alerts;
CREATE POLICY "PDG can manage api_alerts" ON public.api_alerts
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- api_connections
DROP POLICY IF EXISTS "PDG can manage api_connections" ON public.api_connections;
CREATE POLICY "PDG can manage api_connections" ON public.api_connections
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- api_usage_logs
DROP POLICY IF EXISTS "PDG can view api_usage_logs" ON public.api_usage_logs;
CREATE POLICY "PDG can view api_usage_logs" ON public.api_usage_logs
FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- audit_logs (critical - keep service_role but add authenticated for admins)
DROP POLICY IF EXISTS "authenticated_admins_view_audit_logs" ON public.audit_logs;
CREATE POLICY "authenticated_admins_view_audit_logs" ON public.audit_logs
FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- auth_attempts_log
DROP POLICY IF EXISTS "admin_only_auth_attempts" ON public.auth_attempts_log;
CREATE POLICY "admin_only_auth_attempts" ON public.auth_attempts_log
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- badges
DROP POLICY IF EXISTS "Admins peuvent tout voir" ON public.badges;
CREATE POLICY "Admins peuvent tout voir" ON public.badges
FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Bureau peut gérer ses badges" ON public.badges;
CREATE POLICY "Bureau peut gérer ses badges" ON public.badges
FOR ALL TO authenticated
USING (bureau_id IN (SELECT id FROM public.bureaus WHERE user_id = auth.uid()))
WITH CHECK (bureau_id IN (SELECT id FROM public.bureaus WHERE user_id = auth.uid()));

-- balance_reconciliation (financial - critical)
DROP POLICY IF EXISTS "PDG full access to reconciliation" ON public.balance_reconciliation;
CREATE POLICY "PDG full access to reconciliation" ON public.balance_reconciliation
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- beauty_appointments
DROP POLICY IF EXISTS "Beauty appointments owner access" ON public.beauty_appointments;
CREATE POLICY "Beauty appointments owner access" ON public.beauty_appointments
FOR ALL TO authenticated
USING (professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid()))
WITH CHECK (professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid()));

-- beauty_services
DROP POLICY IF EXISTS "Beauty services owner access" ON public.beauty_services;
CREATE POLICY "Beauty services owner access" ON public.beauty_services
FOR ALL TO authenticated
USING (professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid()))
WITH CHECK (professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid()));

-- beauty_staff
DROP POLICY IF EXISTS "Beauty staff owner access" ON public.beauty_staff;
CREATE POLICY "Beauty staff owner access" ON public.beauty_staff
FOR ALL TO authenticated
USING (professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid()))
WITH CHECK (professional_service_id IN (SELECT id FROM public.professional_services WHERE user_id = auth.uid()));

-- blocked_ips
DROP POLICY IF EXISTS "Admins blocked ips" ON public.blocked_ips;
CREATE POLICY "Admins blocked ips" ON public.blocked_ips
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- bug_bounty_hall_of_fame (keep public read for transparency)
DROP POLICY IF EXISTS "Anyone can view hall of fame" ON public.bug_bounty_hall_of_fame;
CREATE POLICY "Anyone can view hall of fame" ON public.bug_bounty_hall_of_fame
FOR SELECT TO anon, authenticated
USING (true);

-- bureau_access_logs
DROP POLICY IF EXISTS "Admins peuvent voir les logs" ON public.bureau_access_logs;
CREATE POLICY "Admins peuvent voir les logs" ON public.bureau_access_logs
FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'));