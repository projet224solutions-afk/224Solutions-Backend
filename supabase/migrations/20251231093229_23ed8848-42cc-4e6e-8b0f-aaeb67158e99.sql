-- Batch 4e: Continue fixing anonymous access policies

-- ai_generated_documents
DROP POLICY IF EXISTS "Users manage own ai documents" ON public.ai_generated_documents;
CREATE POLICY "Users manage own ai documents" ON public.ai_generated_documents
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- audit_logs
DROP POLICY IF EXISTS "authenticated_admins_view_audit_logs" ON public.audit_logs;
DROP POLICY IF EXISTS "users_view_own_audit_logs" ON public.audit_logs;
CREATE POLICY "users_view_own_audit_logs" ON public.audit_logs
  FOR SELECT TO authenticated
  USING (actor_id = auth.uid());
CREATE POLICY "admins_view_all_audit_logs" ON public.audit_logs
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- auth_attempts_log
DROP POLICY IF EXISTS "admin_only_auth_attempts" ON public.auth_attempts_log;
CREATE POLICY "admin_only_auth_attempts" ON public.auth_attempts_log
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- auto_fixes
DROP POLICY IF EXISTS "admin_can_manage_fixes" ON public.auto_fixes;
CREATE POLICY "admin_can_manage_fixes" ON public.auto_fixes
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- badges
DROP POLICY IF EXISTS "Admins view all badges" ON public.badges;
DROP POLICY IF EXISTS "Bureau manage own badges" ON public.badges;
DROP POLICY IF EXISTS "bureau_own_badges" ON public.badges;
CREATE POLICY "bureau_own_badges" ON public.badges
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.bureaus b WHERE b.id = badges.bureau_id AND b.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.bureaus b WHERE b.id = badges.bureau_id AND b.user_id = auth.uid()
  ));
CREATE POLICY "admins_view_all_badges" ON public.badges
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- balance_reconciliation
DROP POLICY IF EXISTS "PDG full access to reconciliation" ON public.balance_reconciliation;
CREATE POLICY "PDG full access to reconciliation" ON public.balance_reconciliation
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.pdg_management pdg WHERE pdg.user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.pdg_management pdg WHERE pdg.user_id = auth.uid()));

-- beauty_appointments
DROP POLICY IF EXISTS "Beauty appointments owner access" ON public.beauty_appointments;
CREATE POLICY "beauty_appointments_owner" ON public.beauty_appointments
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.professional_services ps WHERE ps.id = beauty_appointments.professional_service_id AND ps.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.professional_services ps WHERE ps.id = beauty_appointments.professional_service_id AND ps.user_id = auth.uid()
  ));

-- beauty_services
DROP POLICY IF EXISTS "Beauty services owner access" ON public.beauty_services;
CREATE POLICY "beauty_services_owner" ON public.beauty_services
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.professional_services ps WHERE ps.id = beauty_services.professional_service_id AND ps.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.professional_services ps WHERE ps.id = beauty_services.professional_service_id AND ps.user_id = auth.uid()
  ));

-- beauty_staff
DROP POLICY IF EXISTS "Beauty staff owner access" ON public.beauty_staff;
CREATE POLICY "beauty_staff_owner" ON public.beauty_staff
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.professional_services ps WHERE ps.id = beauty_staff.professional_service_id AND ps.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.professional_services ps WHERE ps.id = beauty_staff.professional_service_id AND ps.user_id = auth.uid()
  ));

-- blocked_ips
DROP POLICY IF EXISTS "Admins manage blocked ips" ON public.blocked_ips;
CREATE POLICY "admins_manage_blocked_ips" ON public.blocked_ips
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- bug_bounty_hall_of_fame
DROP POLICY IF EXISTS "Admins can manage hall of fame" ON public.bug_bounty_hall_of_fame;
CREATE POLICY "admins_manage_hall_of_fame" ON public.bug_bounty_hall_of_fame
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- bug_bounty_rewards
DROP POLICY IF EXISTS "Admins can manage rewards" ON public.bug_bounty_rewards;
CREATE POLICY "admins_manage_rewards" ON public.bug_bounty_rewards
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- bug_reports
DROP POLICY IF EXISTS "Admins manage bug reports" ON public.bug_reports;
CREATE POLICY "admins_manage_bug_reports" ON public.bug_reports
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- bureau_access_logs
DROP POLICY IF EXISTS "Admins view bureau access logs" ON public.bureau_access_logs;
DROP POLICY IF EXISTS "Service role accès complet logs" ON public.bureau_access_logs;
CREATE POLICY "admins_view_bureau_access_logs" ON public.bureau_access_logs
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- bureau_feature_assignments
DROP POLICY IF EXISTS "Admins manage feature assignments" ON public.bureau_feature_assignments;
DROP POLICY IF EXISTS "Bureau view own assignments" ON public.bureau_feature_assignments;
CREATE POLICY "bureau_view_own_assignments" ON public.bureau_feature_assignments
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.bureaus b WHERE b.id = bureau_feature_assignments.bureau_id AND b.user_id = auth.uid()
  ));
CREATE POLICY "admins_manage_feature_assignments" ON public.bureau_feature_assignments
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- bureau_features
DROP POLICY IF EXISTS "Admins manage features" ON public.bureau_features;
DROP POLICY IF EXISTS "Authenticated view active features" ON public.bureau_features;
CREATE POLICY "authenticated_view_active_features" ON public.bureau_features
  FOR SELECT TO authenticated
  USING (is_active = true);
CREATE POLICY "admins_manage_features" ON public.bureau_features
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin'));

-- bureau_transactions
DROP POLICY IF EXISTS "Bureau view own transactions" ON public.bureau_transactions;
DROP POLICY IF EXISTS "PDG manage bureau transactions" ON public.bureau_transactions;
CREATE POLICY "bureau_view_own_transactions" ON public.bureau_transactions
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.bureaus b WHERE b.id = bureau_transactions.bureau_id AND b.user_id = auth.uid()
  ));
CREATE POLICY "pdg_manage_bureau_transactions" ON public.bureau_transactions
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.pdg_management pdg WHERE pdg.user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.pdg_management pdg WHERE pdg.user_id = auth.uid()));

-- bureau_wallets
DROP POLICY IF EXISTS "Bureau view own wallet" ON public.bureau_wallets;
DROP POLICY IF EXISTS "PDG manage all bureau wallets" ON public.bureau_wallets;
CREATE POLICY "bureau_view_own_wallet" ON public.bureau_wallets
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.bureaus b WHERE b.id = bureau_wallets.bureau_id AND b.user_id = auth.uid()
  ));
CREATE POLICY "pdg_manage_all_bureau_wallets" ON public.bureau_wallets
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.pdg_management pdg WHERE pdg.user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.pdg_management pdg WHERE pdg.user_id = auth.uid()));