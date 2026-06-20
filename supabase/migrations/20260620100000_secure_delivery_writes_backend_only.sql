-- ============================================================================
-- 🔒 LIVRAISON — écritures conducteur RÉSERVÉES AU BACKEND (service_role).
--
-- Contexte : accept/start/cancel/track/complete/payment passent désormais par les endpoints
-- backend atomiques (/api/v2/delivery, service_role qui bypass la RLS). On ferme donc les
-- écritures directes depuis le navigateur, sans casser :
--   - la création de livraison (client/vendeur)  → policy INSERT INCHANGÉE
--   - la lecture/suivi (client/vendeur/livreur)   → SELECT conservée/élargie
--   - les mouvements wallet & l'intégrité d'état  → seul le backend écrit
--
-- Bonus fiabilité : la nouvelle SELECT sur delivery_tracking est scopée via la livraison
-- parente → le CLIENT reçoit enfin le tracé via postgres_changes (avant : policy incohérente
-- `driver_id IN drivers.id` alors que les lignes portent driver_id = auth.uid()).
-- ============================================================================

-- ── 1) deliveries : UPDATE — retirer la branche CONDUCTEUR (il écrit via le backend) ────────
-- On conserve client + vendeur (aucun chemin direct conducteur vivant ne subsiste).
DROP POLICY IF EXISTS "deliveries_modify" ON public.deliveries;
CREATE POLICY "deliveries_modify" ON public.deliveries
  FOR UPDATE TO authenticated
  USING (
    client_id = auth.uid()
    OR vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  )
  WITH CHECK (
    client_id = auth.uid()
    OR vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );
-- (deliveries_select et deliveries_insert restent INCHANGÉES — lecture + création préservées.)

-- ── 2) delivery_tracking : lecture scopée par la livraison parente ; ÉCRITURE backend-only ──
ALTER TABLE public.delivery_tracking ENABLE ROW LEVEL SECURITY;

-- Purge des policies historiques (incohérentes / ouvertes en écriture).
DROP POLICY IF EXISTS "Drivers can view their own tracking" ON public.delivery_tracking;
DROP POLICY IF EXISTS "Drivers can insert their own tracking" ON public.delivery_tracking;
DROP POLICY IF EXISTS "Users can view delivery tracking" ON public.delivery_tracking;

-- Lecture seule, pour les parties prenantes de la livraison (livreur, client, vendeur).
-- Aucune policy INSERT/UPDATE/DELETE → seules les écritures service_role (backend) passent.
CREATE POLICY "delivery_tracking_select" ON public.delivery_tracking
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.deliveries d
      WHERE d.id = delivery_tracking.delivery_id
        AND (
          d.driver_id = auth.uid()
          OR d.client_id = auth.uid()
          OR d.vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
        )
    )
  );

SELECT 'Livraison sécurisée : écritures conducteur backend-only (deliveries UPDATE sans branche driver, delivery_tracking écriture service_role) + lecture tracé scopée par livraison (client reçoit le tracé).' AS status;
