-- ============================================================================
-- 🔒 ISOLATION — PALIER 3e-1 : vendeur / commande / stock / expédition.
--
-- Colonnes vérifiées : order_items(order_id→orders.customer_id/vendor_id) ;
--   inventory(product_id→products.vendor_id) ; inventory_history(vendor_id,user_id) ;
--   vendor_ai_*/trust/sentiment/stock(vendor_id) ; shipments(vendor_id) ;
--   shipment_tracking(shipment_id) ; trackings(order_id,user_id) ;
--   international_shipments(order_id,transitaire_id) ; devis_requests(PII, admin).
--
-- Motif vendeur (vendor_id parfois = vendors.id, parfois = user_id selon la table) :
--   vendor_id = auth.uid() OR is_vendor_or_agent(vendor_id) OR is_admin_or_pdg(uid).
--
-- order_items : 🔴 contenait cost_price / profit_* (marges) lisibles par tous +
--   achats d'autrui → scopé aux parties de la commande (acheteur + vendeur) + admin.
--   (Reco ML cross-utilisateur : utiliser product_co_purchases précalculé.)
--
-- ⏭️ 3e-2 (à part) : services pro (education/fitness/restaurant/realestate/
--   hairdresser, service_bookings/products → professional_service_id ; vérifier
--   CustomerReservationTracker) + sous-système entrepôt (warehouse_*/stock_movements,
--   table warehouses owner à confirmer).
--
-- Idempotent. Conserve service_role.
-- ============================================================================

-- ── order_items : parties de la commande (acheteur OU vendeur) + admin ───────
DROP POLICY IF EXISTS "Users can manage order items for their orders" ON public.order_items;
CREATE POLICY "order_items_party_all" ON public.order_items
  FOR ALL TO authenticated
  USING (
    public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.orders o
               WHERE o.id = order_items.order_id
                 AND (o.customer_id = (select auth.uid())
                      OR o.vendor_id IN (SELECT id FROM public.vendors WHERE user_id = (select auth.uid()))))
  )
  WITH CHECK (
    public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.orders o
               WHERE o.id = order_items.order_id
                 AND (o.customer_id = (select auth.uid())
                      OR o.vendor_id IN (SELECT id FROM public.vendors WHERE user_id = (select auth.uid()))))
  );

-- ── inventory : propriétaire via product → vendor + admin ────────────────────
DROP POLICY IF EXISTS "Vendors can manage their inventory" ON public.inventory;
DROP POLICY IF EXISTS "Admins can view all inventory" ON public.inventory;
CREATE POLICY "inventory_vendor_all" ON public.inventory
  FOR ALL TO authenticated
  USING (
    public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.products p JOIN public.vendors v ON v.id = p.vendor_id
               WHERE p.id = inventory.product_id AND v.user_id = (select auth.uid()))
  )
  WITH CHECK (
    public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.products p JOIN public.vendors v ON v.id = p.vendor_id
               WHERE p.id = inventory.product_id AND v.user_id = (select auth.uid()))
  );

-- ── inventory_history : propriétaire (vendor_id / user_id) + admin ───────────
DROP POLICY IF EXISTS "Vendors can view their inventory history" ON public.inventory_history;
CREATE POLICY "inventory_history_owner_select" ON public.inventory_history
  FOR SELECT TO authenticated
  USING (
    user_id = (select auth.uid())
    OR public.is_admin_or_pdg((select auth.uid()))
    OR vendor_id IN (SELECT id FROM public.vendors WHERE user_id = (select auth.uid()))
    OR vendor_id = (select auth.uid())
  );

-- ── vendor_ai_* / trust / sentiment / stock : SELECT scopé au vendeur ────────
-- (les policies service_role ALL sont conservées ; on ne retire QUE le SELECT
--  ouvert {authenticated} et on le remplace par un SELECT scopé vendeur.)
DO $$
DECLARE t text; pol text;
  tables text[] := ARRAY['vendor_ai_control','vendor_ai_decisions','vendor_ai_documents',
    'vendor_ai_execution_logs','vendor_ai_marketing_campaigns','vendor_review_sentiment_analysis',
    'vendor_stock_ai_alerts','vendor_trust_score'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    FOR pol IN
      SELECT p.polname
      FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = t
        AND p.polpermissive AND p.polcmd = 'r'
        AND btrim(lower(pg_get_expr(p.polqual, p.polrelid))) = 'true'
        AND EXISTS (SELECT 1 FROM unnest(p.polroles) r WHERE pg_get_userbyid(r) = 'authenticated')
    LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol, t);
    END LOOP;
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (' ||
      'vendor_id = (select auth.uid()) OR public.is_vendor_or_agent(vendor_id) ' ||
      'OR public.is_admin_or_pdg((select auth.uid())))',
      t || '_owner_select', t);
  END LOOP;
END $$;

-- ── shipments : vendeur propriétaire + admin ─────────────────────────────────
DROP POLICY IF EXISTS "Vendors can view their own shipments" ON public.shipments;
CREATE POLICY "shipments_vendor_select" ON public.shipments
  FOR SELECT TO authenticated
  USING (
    public.is_admin_or_pdg((select auth.uid()))
    OR vendor_id = (select auth.uid())
    OR public.is_vendor_or_agent(vendor_id)
  );

-- ── shipment_tracking : via expédition → vendeur + admin ─────────────────────
DROP POLICY IF EXISTS "Users can view tracking for their shipments" ON public.shipment_tracking;
CREATE POLICY "shipment_tracking_owner_select" ON public.shipment_tracking
  FOR SELECT TO authenticated
  USING (
    public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.shipments s
               WHERE s.id = shipment_tracking.shipment_id
                 AND (s.vendor_id = (select auth.uid()) OR public.is_vendor_or_agent(s.vendor_id)))
  );

-- ── trackings : livreur (user_id) + parties de la commande + admin ───────────
DROP POLICY IF EXISTS "Users can view trackings for their orders" ON public.trackings;
CREATE POLICY "trackings_owner_select" ON public.trackings
  FOR SELECT TO authenticated
  USING (
    user_id = (select auth.uid())
    OR public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.orders o
               WHERE o.id = trackings.order_id
                 AND (o.customer_id = (select auth.uid())
                      OR o.vendor_id IN (SELECT id FROM public.vendors WHERE user_id = (select auth.uid()))))
  );

-- ── international_shipments : transitaire + client (via order) + admin ───────
DROP POLICY IF EXISTS "Transitaires can manage their shipments" ON public.international_shipments;
DROP POLICY IF EXISTS "Customers can view their shipments" ON public.international_shipments;
CREATE POLICY "intl_shipments_party_select" ON public.international_shipments
  FOR SELECT TO authenticated
  USING (
    transitaire_id = (select auth.uid())
    OR public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.orders o
               WHERE o.id = international_shipments.order_id AND o.customer_id = (select auth.uid()))
  );
CREATE POLICY "intl_shipments_transitaire_write" ON public.international_shipments
  FOR ALL TO authenticated
  USING (transitaire_id = (select auth.uid()) OR public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (transitaire_id = (select auth.uid()) OR public.is_admin_or_pdg((select auth.uid())));

-- ── devis_requests : PII (nom/tél/email) → lecture/màj admin ; création publique ─
DROP POLICY IF EXISTS "Admins can view all devis requests" ON public.devis_requests;
DROP POLICY IF EXISTS "Admins can update devis requests" ON public.devis_requests;
CREATE POLICY "devis_admin_select" ON public.devis_requests
  FOR SELECT TO authenticated USING (public.is_admin_or_pdg((select auth.uid())));
CREATE POLICY "devis_admin_update" ON public.devis_requests
  FOR UPDATE TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));
-- (« Anyone can create devis request » INSERT conservée : formulaire public de devis)

SELECT 'Palier 3e-1 OK : order_items (parties commande, marges protégées), inventory/inventory_history (vendeur), vendor_ai_*/trust/sentiment/stock (vendeur), shipments/shipment_tracking/trackings/international_shipments, devis_requests (admin). Reste 3e-2 : services pro + entrepôt.' AS status;
