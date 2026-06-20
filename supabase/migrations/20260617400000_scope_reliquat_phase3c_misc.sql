-- ============================================================================
-- 🔒 ISOLATION — RELIQUAT (config / PWA / transport / ID internes / divers).
--
-- Principe :
--  • CONFIG (lecture légitime large) : on garde le SELECT, on VERROUILLE l'écriture
--    à l'admin (driver_subscription_config, service_plan_price_history, delivery_pricing).
--  • SENSIBLE (lecture réservée) : SELECT → admin/PDG (platform_settings,
--    pwa_installations, taxi_api_usage, id_generation_logs, id_migration_map,
--    driver_subscription_revenues).
--  • TROUS D'ÉCRITURE → admin/backend (pwa_tokens, id_sequences).
--  • DONNÉES owner : push_notifications (user_id), shared_links (created_by),
--    product_recommendations (user_id), transport_* (professional_service_id).
--
-- ✅ LAISSÉ (config lue largement / public voulu) : commission_settings,
--    system_settings (SELECT — fees/KYC/paiement lus par vendeur/client),
--    ids_reserved (lu par usePublicId pour la génération d'ID), bug_reports INSERT
--    (signalement public), bug_bounty_hall_of_fame SELECT (public).
-- ⏭️ agent_created_users (INSERT ouvert) : agents en token custom (comme bureau) →
--    à traiter avec la migration backend agent, pas en RLS auth.uid().
--
-- Idempotent. Conserve service_role.
-- ============================================================================

-- ── CONFIG : write → admin (SELECT conservé) ─────────────────────────────────
DROP POLICY IF EXISTS "Admins manage subscription config" ON public.driver_subscription_config;
CREATE POLICY "driver_sub_config_admin_write" ON public.driver_subscription_config
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Admins can manage price history" ON public.service_plan_price_history;
CREATE POLICY "service_plan_price_history_admin_write" ON public.service_plan_price_history
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "System can insert delivery pricing" ON public.delivery_pricing;
CREATE POLICY "delivery_pricing_admin_insert" ON public.delivery_pricing
  FOR INSERT TO authenticated
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

-- ── SENSIBLE : SELECT → admin/PDG ────────────────────────────────────────────
DROP POLICY IF EXISTS "admins_read_only" ON public.platform_settings;
CREATE POLICY "platform_settings_admin_select" ON public.platform_settings
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Admins peuvent tout voir" ON public.pwa_installations;
CREATE POLICY "pwa_installations_admin_select" ON public.pwa_installations
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Admin can view API usage" ON public.taxi_api_usage;
CREATE POLICY "taxi_api_usage_admin_select" ON public.taxi_api_usage
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Admins can view logs" ON public.id_generation_logs;
CREATE POLICY "id_generation_logs_admin_select" ON public.id_generation_logs
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Anyone can view id migration map" ON public.id_migration_map;
CREATE POLICY "id_migration_map_admin_select" ON public.id_migration_map
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Admins manage revenues" ON public.driver_subscription_revenues;
CREATE POLICY "driver_sub_revenues_admin_all" ON public.driver_subscription_revenues
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

-- ── TROUS D'ÉCRITURE → admin/backend ─────────────────────────────────────────
DROP POLICY IF EXISTS "Admins peuvent gérer les tokens" ON public.pwa_tokens;
CREATE POLICY "pwa_tokens_admin_all" ON public.pwa_tokens
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

-- id_sequences : compteurs d'ID internes → backend-only (service_role BYPASSRLS).
DROP POLICY IF EXISTS "Allow insert/update id_sequences for authenticated users" ON public.id_sequences;
DROP POLICY IF EXISTS "Allow read id_sequences for authenticated users" ON public.id_sequences;

-- ── DONNÉES owner ────────────────────────────────────────────────────────────
-- push_notifications : maj par le propriétaire (user_id).
DROP POLICY IF EXISTS "Users update their notifications" ON public.push_notifications;
CREATE POLICY "push_notifications_owner_update" ON public.push_notifications
  FOR UPDATE TO authenticated
  USING (user_id = (select auth.uid()))
  WITH CHECK (user_id = (select auth.uid()));

-- shared_links : maj par le créateur (created_by) ; INSERT conservé (partage).
DROP POLICY IF EXISTS "Users can update their own shared links" ON public.shared_links;
CREATE POLICY "shared_links_owner_update" ON public.shared_links
  FOR UPDATE TO authenticated
  USING (created_by = (select auth.uid()))
  WITH CHECK (created_by = (select auth.uid()));

-- product_recommendations : le propriétaire voit ses recommandations (user_id).
DROP POLICY IF EXISTS "Users can view own recommendations" ON public.product_recommendations;
CREATE POLICY "product_recommendations_owner_select" ON public.product_recommendations
  FOR SELECT TO authenticated
  USING (user_id = (select auth.uid()) OR public.is_admin_or_pdg((select auth.uid())));

-- transport_vehicles : flotte interne du prestataire de transport.
DROP POLICY IF EXISTS "Transport vehicles owner access" ON public.transport_vehicles;
CREATE POLICY "transport_vehicles_owner_all" ON public.transport_vehicles
  FOR ALL TO authenticated
  USING (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())));

-- transport_rides : offres de trajets → lecture publique (découverte/réservation) +
-- écriture prestataire (comme les catalogues de services).
DROP POLICY IF EXISTS "Transport rides owner access" ON public.transport_rides;
CREATE POLICY "transport_rides_public_select" ON public.transport_rides
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "transport_rides_owner_write" ON public.transport_rides
  FOR ALL TO authenticated
  USING (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())));

SELECT 'Reliquat C OK : config (write admin), sensibles (SELECT admin), pwa_tokens/id_sequences (admin/backend), push_notifications/shared_links/product_recommendations (owner), transport_* (prestataire/public). Laissés : commission_settings/system_settings/ids_reserved (config lue), bug_*. agent_created_users INSERT → migration backend agent.' AS status;
