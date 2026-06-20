-- ============================================================================
-- 🔒 ISOLATION — PALIER 3f : sécurité / SOC / monitoring → admin/PDG-only.
--
-- Ces tables (incidents, règles WAF, modèles de fraude, SOC, logs webhook, métriques
-- sécurité) étaient lisibles par TOUT compte connecté (SELECT/ALL `true`) alors
-- qu'elles ne doivent l'être que par l'admin/PDG (dashboards WAFDashboard,
-- EnhancedSOCDashboard, AdvancedMLFraudDetection, RealTimeSecurityDashboard,
-- PDGApiSupervision, AlertsDashboard…). On scope les SELECT/ALL en is_admin_or_pdg.
--
-- ✅ NON MODIFIÉ (déjà correct) : error_logs, system_errors, system_health,
--    system_health_logs, performance_metrics, secure_logs, health_check_reports,
--    monitoring_alerts/events/metrics/service_status → SELECT déjà scopé admin +
--    INSERT ouvert volontaire (logging client best-effort). Aucune fuite de lecture.
--
-- Idempotent. Les INSERT de logging et policies service_role sont conservés.
-- ============================================================================

-- ── Tables « ALL true » → ALL admin/PDG ──────────────────────────────────────
DROP POLICY IF EXISTS "PDG full access to signatures" ON public.module_signatures;
CREATE POLICY "module_signatures_admin_all" ON public.module_signatures
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Admins detection rules" ON public.security_detection_rules;
CREATE POLICY "security_detection_rules_admin_all" ON public.security_detection_rules
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Admins metrics" ON public.security_metrics;
CREATE POLICY "security_metrics_admin_all" ON public.security_metrics
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Admins can manage SOC analysts" ON public.soc_analysts;
CREATE POLICY "soc_analysts_admin_all" ON public.soc_analysts
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Admins can manage SOC investigations" ON public.soc_investigations;
CREATE POLICY "soc_investigations_admin_all" ON public.soc_investigations
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Admins can manage WAF rules" ON public.waf_rules;
CREATE POLICY "waf_rules_admin_all" ON public.waf_rules
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "admin_only_webhook_audit" ON public.webhook_audit_logs;
CREATE POLICY "webhook_audit_admin_all" ON public.webhook_audit_logs
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "admin_only_webhook_events" ON public.webhook_processed_events;
CREATE POLICY "webhook_events_admin_all" ON public.webhook_processed_events
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

-- ── Tables « SELECT true » → SELECT admin/PDG ────────────────────────────────
DROP POLICY IF EXISTS "Admins can view ML models" ON public.ml_fraud_models;
CREATE POLICY "ml_fraud_models_admin_select" ON public.ml_fraud_models
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Admins can view ML patterns" ON public.ml_fraud_patterns;
CREATE POLICY "ml_fraud_patterns_admin_select" ON public.ml_fraud_patterns
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Admins can view WAF logs" ON public.waf_logs;
CREATE POLICY "waf_logs_admin_select" ON public.waf_logs
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Admins can view WAF stats" ON public.waf_stats;
CREATE POLICY "waf_stats_admin_select" ON public.waf_stats
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));

-- ── security_incidents : SELECT ouvert redondant (policies admin scopées existent) ─
DROP POLICY IF EXISTS "Admins can view all security data" ON public.security_incidents;
-- (« Admins can read/insert/update/manage security incidents » scopées conservées)

-- ── system_alerts : SELECT/DELETE/UPDATE ouverts → admin ; INSERT (logging) +
-- agent_read_system_alerts (scopé) conservés. ───────────────────────────────
DROP POLICY IF EXISTS "Users can view all system alerts" ON public.system_alerts;
DROP POLICY IF EXISTS "Admins can delete system alerts" ON public.system_alerts;
DROP POLICY IF EXISTS "Admins can acknowledge system alerts" ON public.system_alerts;
CREATE POLICY "system_alerts_admin_select" ON public.system_alerts
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));
CREATE POLICY "system_alerts_admin_delete" ON public.system_alerts
  FOR DELETE TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));
CREATE POLICY "system_alerts_admin_update" ON public.system_alerts
  FOR UPDATE TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));
-- (« Admins can create system alerts » INSERT conservée = logging alertingService ;
--  « agent_read_system_alerts » SELECT scopée conservée pour les agents)

SELECT 'Palier 3f OK : sécurité/SOC/WAF/fraude/webhook/module_signatures/system_alerts → SELECT/ALL admin-PDG. Logging (error_logs/system_errors/monitoring_*/secure_logs/...) déjà correct (SELECT admin + INSERT ouvert), non touché. LOT 3f TERMINÉ.' AS status;
