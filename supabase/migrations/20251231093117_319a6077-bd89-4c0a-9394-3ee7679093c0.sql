-- Batch 4d: Fix anonymous access policies by adding TO authenticated

-- advanced_carts
DROP POLICY IF EXISTS "authenticated_users_manage_own_cart" ON public.advanced_carts;
CREATE POLICY "authenticated_users_manage_own_cart" ON public.advanced_carts
  FOR ALL TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- agent_commissions_log
DROP POLICY IF EXISTS "Agents can view own commission logs" ON public.agent_commissions_log;
DROP POLICY IF EXISTS "PDG can view all commission logs" ON public.agent_commissions_log;
CREATE POLICY "Agents can view own commission logs" ON public.agent_commissions_log
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am 
    WHERE am.id = agent_commissions_log.agent_id AND am.user_id = auth.uid()
  ));
CREATE POLICY "PDG can view all commission logs" ON public.agent_commissions_log
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.pdg_management pdg WHERE pdg.user_id = auth.uid()
  ));

-- agent_created_users
DROP POLICY IF EXISTS "Agents can view sub-agents created users" ON public.agent_created_users;
DROP POLICY IF EXISTS "PDG can view all agent_created_users" ON public.agent_created_users;
DROP POLICY IF EXISTS "agents_view_created_users" ON public.agent_created_users;
CREATE POLICY "agents_view_created_users" ON public.agent_created_users
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am 
    WHERE am.id = agent_created_users.agent_id AND am.user_id = auth.uid()
  ));
CREATE POLICY "PDG can view all agent_created_users" ON public.agent_created_users
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.pdg_management pdg WHERE pdg.user_id = auth.uid()
  ));

-- agent_permissions
DROP POLICY IF EXISTS "Agent can view own permissions" ON public.agent_permissions;
DROP POLICY IF EXISTS "PDG can manage agent permissions" ON public.agent_permissions;
CREATE POLICY "Agent can view own permissions" ON public.agent_permissions
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am 
    WHERE am.id = agent_permissions.agent_id AND am.user_id = auth.uid()
  ));
CREATE POLICY "PDG can manage agent permissions" ON public.agent_permissions
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am 
    JOIN public.pdg_management pdg ON pdg.id = am.pdg_id
    WHERE am.id = agent_permissions.agent_id AND pdg.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.agents_management am 
    JOIN public.pdg_management pdg ON pdg.id = am.pdg_id
    WHERE am.id = agent_permissions.agent_id AND pdg.user_id = auth.uid()
  ));

-- agents table
DROP POLICY IF EXISTS "Vendors can manage their agents" ON public.agents;
DROP POLICY IF EXISTS "users_own_agents" ON public.agents;
CREATE POLICY "users_own_agents" ON public.agents
  FOR ALL TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- agents_management
DROP POLICY IF EXISTS "agents_management_select" ON public.agents_management;
DROP POLICY IF EXISTS "PDG can manage agents" ON public.agents_management;
DROP POLICY IF EXISTS "agents_view_own" ON public.agents_management;
CREATE POLICY "agents_view_own" ON public.agents_management
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());
CREATE POLICY "PDG can manage agents" ON public.agents_management
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.pdg_management pdg WHERE pdg.id = agents_management.pdg_id AND pdg.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.pdg_management pdg WHERE pdg.id = agents_management.pdg_id AND pdg.user_id = auth.uid()
  ));

-- api_alerts
DROP POLICY IF EXISTS "admin_manage_api_alerts" ON public.api_alerts;
CREATE POLICY "admin_manage_api_alerts" ON public.api_alerts
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- api_connections
DROP POLICY IF EXISTS "admin_manage_api_connections" ON public.api_connections;
CREATE POLICY "admin_manage_api_connections" ON public.api_connections
  FOR ALL TO authenticated
  USING (created_by = auth.uid() OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'))
  WITH CHECK (created_by = auth.uid() OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- api_keys
DROP POLICY IF EXISTS "users_manage_own_api_keys" ON public.api_keys;
CREATE POLICY "users_manage_own_api_keys" ON public.api_keys
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- api_usage
DROP POLICY IF EXISTS "users_view_own_api_usage" ON public.api_usage;
CREATE POLICY "users_view_own_api_usage" ON public.api_usage
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.api_keys ak WHERE ak.id = api_usage.api_key_id AND ak.user_id = auth.uid()
  ));

-- api_usage_logs
DROP POLICY IF EXISTS "admin_view_api_usage_logs" ON public.api_usage_logs;
CREATE POLICY "admin_view_api_usage_logs" ON public.api_usage_logs
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));