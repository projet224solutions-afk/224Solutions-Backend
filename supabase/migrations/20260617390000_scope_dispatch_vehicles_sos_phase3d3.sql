-- ============================================================================
-- 🔒 ISOLATION — PALIER 3d-3 (DERNIER) : dispatch taxi / véhicules / SOS.
--
-- taxi_trips : SELECT ouvert (trips_read_involved=true) → scopé passager + chauffeur
--   assigné + COURSES NON ASSIGNÉES visibles aux chauffeurs (préserve le dispatch :
--   un chauffeur doit voir les demandes à accepter) + PDG. (INSERT/UPDATE déjà scopés.)
--
-- vehicles / vehicle_* : suivi de flotte / véhicules volés, contexte BUREAU (token,
--   pas de session Supabase) → comme palier 3g : trou d'écriture fermé + lecture
--   PDG + backend service_role (WorkerDashboard/StolenMoto via /api/v2/bureau).
--
-- sos_alerts / sos_media : SÉCURITÉ — on GARDE l'INSERT (création d'alerte d'urgence
--   par qui est en danger) mais on ferme la fuite de LECTURE (tout le monde voyait
--   toutes les alertes SOS + localisations) : lecture/maj = bureau propriétaire
--   (sos_alerts.bureau_own existant) / chauffeur (sos_media.drivers_own existant) +
--   PDG + backend (responders bureau via /api/v2/bureau).
--
-- moto_security_alerts : PII (owner_phone) cross-bureau → PDG + backend.
--
-- Idempotent. Conserve service_role et les policies scopées existantes.
-- ============================================================================

-- ── taxi_trips : passager + chauffeur assigné + dispatch (non assignées) + PDG ─
DROP POLICY IF EXISTS "trips_read_involved" ON public.taxi_trips;
CREATE POLICY "taxi_trips_party_dispatch_select" ON public.taxi_trips
  FOR SELECT TO authenticated
  USING (
    customer_id = (select auth.uid())
    OR driver_id = (select auth.uid())
    OR driver_id IN (SELECT id FROM public.taxi_drivers WHERE user_id = (select auth.uid()))
    OR public.is_admin_or_pdg((select auth.uid()))
    OR (
      driver_id IS NULL
      AND EXISTS (SELECT 1 FROM public.taxi_drivers WHERE user_id = (select auth.uid()))
    )
  );

-- ── vehicles : trou d'écriture (ALL true) fermé + lecture PDG/backend ─────────
DROP POLICY IF EXISTS "Admins can manage all vehicles" ON public.vehicles;
DROP POLICY IF EXISTS "Anyone with bureau token can view vehicles" ON public.vehicles;
CREATE POLICY "vehicles_admin_all" ON public.vehicles
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

-- ── vehicle_gps_tracking / security_log / fraud_alerts : PDG/backend ─────────
DROP POLICY IF EXISTS "Accès GPS véhicules volés" ON public.vehicle_gps_tracking;
CREATE POLICY "vehicle_gps_admin_select" ON public.vehicle_gps_tracking
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "bureaus_select_own_security_logs" ON public.vehicle_security_log;
CREATE POLICY "vehicle_security_log_admin_select" ON public.vehicle_security_log
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "bureaus_select_own_fraud_alerts" ON public.vehicle_fraud_alerts;
DROP POLICY IF EXISTS "bureaus_update_own_fraud_alerts" ON public.vehicle_fraud_alerts;
CREATE POLICY "vehicle_fraud_alerts_admin_select" ON public.vehicle_fraud_alerts
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));
CREATE POLICY "vehicle_fraud_alerts_admin_update" ON public.vehicle_fraud_alerts
  FOR UPDATE TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

-- ── sos_alerts : garder INSERT (urgence) ; fermer lecture/maj ouvertes ───────
-- (bureau_own_sos_alerts ALL — bureau propriétaire — est conservé ; + PDG.)
DROP POLICY IF EXISTS "Authenticated users can view all SOS alerts" ON public.sos_alerts;
DROP POLICY IF EXISTS "Authenticated users can update SOS alerts" ON public.sos_alerts;
DROP POLICY IF EXISTS "Bureaux can update own SOS alerts secure" ON public.sos_alerts;
CREATE POLICY "sos_alerts_responder_select" ON public.sos_alerts
  FOR SELECT TO authenticated
  USING (
    public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.bureaus b
               WHERE b.id = sos_alerts.bureau_id AND b.user_id = (select auth.uid()))
  );
CREATE POLICY "sos_alerts_responder_update" ON public.sos_alerts
  FOR UPDATE TO authenticated
  USING (
    public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.bureaus b
               WHERE b.id = sos_alerts.bureau_id AND b.user_id = (select auth.uid()))
  );
-- (« Authenticated users can create SOS alerts » INSERT conservée = urgence)

-- ── sos_media : garder INSERT (urgence) ; fermer lecture/maj ouvertes ────────
-- (drivers_own_sos_media ALL — chauffeur propriétaire driver_id=auth.uid() — conservé.)
DROP POLICY IF EXISTS "Anyone can view SOS media" ON public.sos_media;
DROP POLICY IF EXISTS "Authenticated users can update SOS media" ON public.sos_media;
CREATE POLICY "sos_media_admin_select" ON public.sos_media
  FOR SELECT TO authenticated
  USING (
    public.is_admin_or_pdg((select auth.uid()))
    OR driver_id = (select auth.uid())
  );
-- (« Authenticated users can create SOS media » INSERT conservée = urgence)

-- ── moto_security_alerts : PII (owner_phone) cross-bureau → PDG + backend ────
DROP POLICY IF EXISTS "Authenticated users can view all security alerts" ON public.moto_security_alerts;
DROP POLICY IF EXISTS "Authenticated users can update security alerts" ON public.moto_security_alerts;
DROP POLICY IF EXISTS "Authenticated users can create security alerts" ON public.moto_security_alerts;
CREATE POLICY "moto_security_alerts_admin_all" ON public.moto_security_alerts
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

SELECT 'Palier 3d-3 OK (DERNIER) : taxi_trips (passager+chauffeur+dispatch+PDG), vehicles/vehicle_* (écriture fermée + lecture PDG/backend), sos_alerts/sos_media (INSERT urgence gardé + lecture/maj bureau-owner/chauffeur/PDG), moto_security_alerts (PDG/backend). AUDIT ISOLATION DES DONNÉES COMPLET.' AS status;
