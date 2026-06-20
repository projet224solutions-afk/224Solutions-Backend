-- ============================================================================
-- 🔒 ISOLATION — PALIER 3d-1 : livraison / courses / chauffeurs (cas sûrs).
--
-- Objectif = LECTURE isolée. Beaucoup de ces tables ont DÉJÀ une policy scopée
-- (propriétaire / parties) doublée d'une policy `true` qui l'annule → on retire
-- les ouvertes redondantes. On préserve les lectures nécessaires au métier
-- (suivi livraison côté client, découverte chauffeurs côté client).
--
-- Vérifs frontend : delivery_offers = 0 accès direct (dispatch backend) ;
-- delivery_tracking lu par le client (useDelivery) → SELECT laissé ; taxi_drivers
-- lu pour la découverte (NearbyTaxiMoto, TaxiMotoClient…) → SELECT laissé, mais le
-- trou d'ÉCRITURE (driver_manage_self = ALL true) est fermé.
--
-- ⏭️ 3d-2 (à part, colonnes requises) : taxi_driver_documents (KYC), taxi_trips/
--    taxi_messages/taxi_notifications/taxi_rides, vehicle_*, vehicles, sos_alerts/
--    sos_media (sécurité), moto_security_alerts, transport_ticket_batches.
--
-- Idempotent. Conserve service_role + scopées.
-- ============================================================================

-- ── delivery_logs : SELECT ouvert redondant (ALL user_id=self couvre) ────────
DROP POLICY IF EXISTS "Users can view logs for their deliveries" ON public.delivery_logs;

-- ── delivery_notifications : SELECT + UPDATE ouverts redondants (ALL user_id) ─
DROP POLICY IF EXISTS "Users can view their own delivery notifications" ON public.delivery_notifications;
DROP POLICY IF EXISTS "Users can update their own delivery notifications" ON public.delivery_notifications;

-- ── delivery_messages : SELECT + INSERT ouverts redondants ; UPDATE rescopé ──
-- (ALL users_own couvre SELECT [sender|recipient] et INSERT [check sender=self])
DROP POLICY IF EXISTS "Les utilisateurs peuvent voir leurs propres messages de livrais" ON public.delivery_messages;
DROP POLICY IF EXISTS "Les utilisateurs peuvent envoyer des messages de livraison" ON public.delivery_messages;
DROP POLICY IF EXISTS "Les utilisateurs peuvent mettre à jour leurs messages reçus" ON public.delivery_messages;
DROP POLICY IF EXISTS "delivery_messages_party_update" ON public.delivery_messages;
CREATE POLICY "delivery_messages_party_update" ON public.delivery_messages
  FOR UPDATE TO authenticated
  USING (sender_id = (select auth.uid()) OR recipient_id = (select auth.uid()))
  WITH CHECK (sender_id = (select auth.uid()) OR recipient_id = (select auth.uid()));

-- ── delivery_offers : ouvertes redondantes (2 policies ALL driver couvrent) ──
DROP POLICY IF EXISTS "System can insert offers" ON public.delivery_offers;
DROP POLICY IF EXISTS "Drivers can view their own offers" ON public.delivery_offers;
DROP POLICY IF EXISTS "Drivers can update their own offers" ON public.delivery_offers;

-- ── delivery_tracking : INSERT ouvert redondant (ALL driver couvre) ; SELECT
-- LAISSÉ (le client suit sa livraison — dépendance useDelivery). ─────────────
DROP POLICY IF EXISTS "Drivers can insert their own tracking" ON public.delivery_tracking;

-- ── rides : SELECT + INSERT ouverts redondants (ALL customer|driver couvre) ──
DROP POLICY IF EXISTS "Customers can view their rides" ON public.rides;
DROP POLICY IF EXISTS "Customers can create rides" ON public.rides;

-- ── taxi_drivers : fermer le trou d'ÉCRITURE (driver_manage_self = ALL true).
-- users_own_taxi_drivers (ALL user_id=self) gère l'écriture du chauffeur ;
-- drivers_read_self (SELECT) est LAISSÉ pour la découverte côté client. ───────
DROP POLICY IF EXISTS "driver_manage_self" ON public.taxi_drivers;

-- ── registered_motos : DELETE ouvert dangereux (redondant avec les ALL admin) ─
DROP POLICY IF EXISTS "Admins can delete motos" ON public.registered_motos;

SELECT 'Palier 3d-1 OK : delivery_logs/notifications/messages/offers/tracking + rides — ouvertes redondantes retirées (lecture scopée restaurée, suivi client & découverte chauffeurs préservés) ; taxi_drivers trou écriture fermé ; registered_motos DELETE ouvert retiré. Reste 3d-2 (KYC, taxi_trips, véhicules, SOS).' AS status;
