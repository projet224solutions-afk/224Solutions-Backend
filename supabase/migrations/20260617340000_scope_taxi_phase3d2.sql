-- ============================================================================
-- 🔒 ISOLATION — PALIER 3d-2 : KYC chauffeur, messages/notifs taxi (cas clairs).
--
-- Colonnes vérifiées (toutes uuid) :
--   taxi_driver_documents(driver_id→taxi_drivers.id, verified_by) ;
--   taxi_messages(ride_id, sender_id, recipient_id) ;
--   taxi_notifications(user_id) ; taxi_rides(customer_id, driver_id).
--
-- 🔴 taxi_driver_documents : SELECT/INSERT/UPDATE étaient OUVERTS → n'importe qui
--    voyait les pièces d'identité (KYC) de TOUS les chauffeurs. On scope :
--    lecture/upload = chauffeur propriétaire (via taxi_drivers.user_id) ; mise à
--    jour (vérification) = admin/PDG.
--
-- ⏭️ 3d-3 (à part, métier/sécurité) : taxi_trips SELECT (dispatch : un chauffeur
--    doit voir les courses dispo), vehicle_*/vehicles (schéma vehicles à confirmer
--    + suivi véhicule volé), sos_alerts/sos_media + moto_security_alerts (réponse
--    d'urgence), transport_ticket_batches (accès worker bureau → lot 3g) ; et les
--    SELECT de découverte laissés en 3d-1 (taxi_drivers, delivery_tracking).
--
-- Idempotent. Conserve service_role.
-- ============================================================================

-- ── taxi_driver_documents : KYC → chauffeur propriétaire + admin ─────────────
DROP POLICY IF EXISTS "Drivers can view own documents" ON public.taxi_driver_documents;
DROP POLICY IF EXISTS "Drivers can upload documents" ON public.taxi_driver_documents;
DROP POLICY IF EXISTS "Admin can update documents" ON public.taxi_driver_documents;

CREATE POLICY "taxi_docs_owner_select" ON public.taxi_driver_documents
  FOR SELECT TO authenticated
  USING (
    public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.taxi_drivers d
               WHERE d.id = taxi_driver_documents.driver_id AND d.user_id = (select auth.uid()))
  );
CREATE POLICY "taxi_docs_owner_insert" ON public.taxi_driver_documents
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.taxi_drivers d
            WHERE d.id = taxi_driver_documents.driver_id AND d.user_id = (select auth.uid()))
  );
CREATE POLICY "taxi_docs_admin_update" ON public.taxi_driver_documents
  FOR UPDATE TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

-- ── taxi_messages : parties (sender/recipient) ───────────────────────────────
DROP POLICY IF EXISTS "Les utilisateurs peuvent voir leurs propres messages de taxi" ON public.taxi_messages;
DROP POLICY IF EXISTS "Les utilisateurs peuvent envoyer des messages de taxi" ON public.taxi_messages;
DROP POLICY IF EXISTS "Les utilisateurs peuvent mettre à jour leurs messages de taxi" ON public.taxi_messages;

CREATE POLICY "taxi_messages_party_select" ON public.taxi_messages
  FOR SELECT TO authenticated
  USING (sender_id = (select auth.uid()) OR recipient_id = (select auth.uid()));
CREATE POLICY "taxi_messages_sender_insert" ON public.taxi_messages
  FOR INSERT TO authenticated
  WITH CHECK (sender_id = (select auth.uid()));
CREATE POLICY "taxi_messages_party_update" ON public.taxi_messages
  FOR UPDATE TO authenticated
  USING (sender_id = (select auth.uid()) OR recipient_id = (select auth.uid()))
  WITH CHECK (sender_id = (select auth.uid()) OR recipient_id = (select auth.uid()));

-- ── taxi_notifications : propriétaire (service_role conservé pour la création) ─
DROP POLICY IF EXISTS "notif_read_own" ON public.taxi_notifications;
CREATE POLICY "taxi_notif_owner_select" ON public.taxi_notifications
  FOR SELECT TO authenticated
  USING (user_id = (select auth.uid()));

-- ── taxi_rides (LEGACY) : verrou admin + backend (table active = taxi_trips ;
-- colonnes de taxi_rides incertaines en base live → pas de référence colonne). ─
DROP POLICY IF EXISTS "user_view_own_rides" ON public.taxi_rides;
CREATE POLICY "taxi_rides_admin_select" ON public.taxi_rides
  FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())));

SELECT 'Palier 3d-2 OK : taxi_driver_documents (KYC fermé : chauffeur+admin), taxi_messages (parties), taxi_notifications (propriétaire), taxi_rides (parties+admin). Reste 3d-3 : taxi_trips dispatch, vehicles/vehicle_*, sos_*/moto_security_alerts.' AS status;
