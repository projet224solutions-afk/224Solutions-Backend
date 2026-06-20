-- ============================================================================
-- 🔒 ISOLATION — PALIER 3e-2 : services pro + sous-système entrepôt.
--
-- Helper réutilisé : is_service_owner_or_agent(ps_id) (SECURITY DEFINER, propriétaire
-- du professional_service OU agent). professional_services.user_id = le prestataire.
-- warehouses.vendor_id → vendors.id → vendors.user_id (propriétaire entrepôt).
--
-- Tiers :
--  • CATALOGUE (lecture publique = découverte client ; écriture = prestataire) :
--    education_courses, fitness_classes, realestate_properties.
--  • INTERNE prestataire : restaurant_staff, restaurant_stock.
--  • ENREGISTREMENTS CLIENTS (PII : nom/tél/email) = prestataire + le client concerné
--    (match email ; service_bookings via client_id) : restaurant_reservations,
--    fitness_memberships, education_enrollments, realestate_visits,
--    hairdresser_appointments, service_bookings.
--    → préserve CustomerReservationTracker (filtre customer_email = user.email).
--  • ENTREPÔT : warehouse_stocks, warehouse_permissions, stock_movements.
--
-- Idempotent. Conserve service_role.
-- ============================================================================

-- ════════════ CATALOGUE : lecture publique + écriture prestataire ════════════
DROP POLICY IF EXISTS "Education courses owner access" ON public.education_courses;
CREATE POLICY "education_courses_public_select" ON public.education_courses
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "education_courses_owner_write" ON public.education_courses
  FOR ALL TO authenticated
  USING (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Fitness classes owner access" ON public.fitness_classes;
CREATE POLICY "fitness_classes_public_select" ON public.fitness_classes
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "fitness_classes_owner_write" ON public.fitness_classes
  FOR ALL TO authenticated
  USING (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Realestate properties owner access" ON public.realestate_properties;
CREATE POLICY "realestate_properties_public_select" ON public.realestate_properties
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "realestate_properties_owner_write" ON public.realestate_properties
  FOR ALL TO authenticated
  USING (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())));

-- ════════════ INTERNE prestataire (staff / stock) ════════════════════════════
DROP POLICY IF EXISTS "Restaurant staff owner access" ON public.restaurant_staff;
CREATE POLICY "restaurant_staff_owner_all" ON public.restaurant_staff
  FOR ALL TO authenticated
  USING (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())));

DROP POLICY IF EXISTS "Restaurant stock owner access" ON public.restaurant_stock;
CREATE POLICY "restaurant_stock_owner_all" ON public.restaurant_stock
  FOR ALL TO authenticated
  USING (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())));

-- ════════════ ENREGISTREMENTS CLIENTS (prestataire + client) ═════════════════
-- restaurant_reservations : prestataire OU client (email) ; INSERT = booking client/prestataire.
DROP POLICY IF EXISTS "Restaurant reservations owner access" ON public.restaurant_reservations;
CREATE POLICY "restaurant_reservations_select" ON public.restaurant_reservations
  FOR SELECT TO authenticated
  USING (
    public.is_service_owner_or_agent(professional_service_id)
    OR customer_email = ((select auth.jwt()) ->> 'email')
    OR public.is_admin_or_pdg((select auth.uid()))
  );
CREATE POLICY "restaurant_reservations_insert" ON public.restaurant_reservations
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_service_owner_or_agent(professional_service_id)
    OR customer_email = ((select auth.jwt()) ->> 'email')
  );
CREATE POLICY "restaurant_reservations_update" ON public.restaurant_reservations
  FOR UPDATE TO authenticated
  USING (
    public.is_service_owner_or_agent(professional_service_id)
    OR customer_email = ((select auth.jwt()) ->> 'email')
    OR public.is_admin_or_pdg((select auth.uid()))
  );

-- fitness_memberships : prestataire OU membre (email).
DROP POLICY IF EXISTS "Fitness memberships owner access" ON public.fitness_memberships;
CREATE POLICY "fitness_memberships_select" ON public.fitness_memberships
  FOR SELECT TO authenticated
  USING (
    public.is_service_owner_or_agent(professional_service_id)
    OR member_email = ((select auth.jwt()) ->> 'email')
    OR public.is_admin_or_pdg((select auth.uid()))
  );
CREATE POLICY "fitness_memberships_write" ON public.fitness_memberships
  FOR ALL TO authenticated
  USING (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())));

-- education_enrollments : prestataire (via course) OU étudiant (email).
DROP POLICY IF EXISTS "Education enrollments access" ON public.education_enrollments;
CREATE POLICY "education_enrollments_select" ON public.education_enrollments
  FOR SELECT TO authenticated
  USING (
    public.is_service_owner_or_agent((SELECT professional_service_id FROM public.education_courses WHERE id = education_enrollments.course_id))
    OR student_email = ((select auth.jwt()) ->> 'email')
    OR public.is_admin_or_pdg((select auth.uid()))
  );
CREATE POLICY "education_enrollments_write" ON public.education_enrollments
  FOR ALL TO authenticated
  USING (public.is_service_owner_or_agent((SELECT professional_service_id FROM public.education_courses WHERE id = education_enrollments.course_id)) OR public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_service_owner_or_agent((SELECT professional_service_id FROM public.education_courses WHERE id = education_enrollments.course_id)) OR public.is_admin_or_pdg((select auth.uid())));

-- realestate_visits : prestataire (via property) OU visiteur (email).
DROP POLICY IF EXISTS "Realestate visits access" ON public.realestate_visits;
CREATE POLICY "realestate_visits_select" ON public.realestate_visits
  FOR SELECT TO authenticated
  USING (
    public.is_service_owner_or_agent((SELECT professional_service_id FROM public.realestate_properties WHERE id = realestate_visits.property_id))
    OR visitor_email = ((select auth.jwt()) ->> 'email')
    OR public.is_admin_or_pdg((select auth.uid()))
  );
CREATE POLICY "realestate_visits_write" ON public.realestate_visits
  FOR ALL TO authenticated
  USING (public.is_service_owner_or_agent((SELECT professional_service_id FROM public.realestate_properties WHERE id = realestate_visits.property_id)) OR public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (true);

-- hairdresser_appointments : prestataire + admin (lecture/gestion) ; INSERT = prise de RDV.
DROP POLICY IF EXISTS "Hairdresser appointments owner access" ON public.hairdresser_appointments;
CREATE POLICY "hairdresser_appointments_owner" ON public.hairdresser_appointments
  FOR ALL TO authenticated
  USING (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_service_owner_or_agent(professional_service_id) OR public.is_admin_or_pdg((select auth.uid())));
CREATE POLICY "hairdresser_appointments_book" ON public.hairdresser_appointments
  FOR INSERT TO authenticated
  WITH CHECK (true);

-- service_bookings : client (client_id) OU prestataire + admin.
DROP POLICY IF EXISTS "Users can view their bookings" ON public.service_bookings;
DROP POLICY IF EXISTS "Clients can create bookings" ON public.service_bookings;
CREATE POLICY "service_bookings_party_select" ON public.service_bookings
  FOR SELECT TO authenticated
  USING (
    client_id = (select auth.uid())
    OR public.is_service_owner_or_agent(professional_service_id)
    OR public.is_admin_or_pdg((select auth.uid()))
  );
CREATE POLICY "service_bookings_client_insert" ON public.service_bookings
  FOR INSERT TO authenticated
  WITH CHECK (client_id = (select auth.uid()));
-- (« Service owners can update bookings » service_role conservée)

-- ════════════ ENTREPÔT (vendeur via warehouses.vendor_id + permissions) ══════
DROP POLICY IF EXISTS "Vendors can manage their warehouse stocks" ON public.warehouse_stocks;
CREATE POLICY "warehouse_stocks_owner_all" ON public.warehouse_stocks
  FOR ALL TO authenticated
  USING (
    public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.warehouses w JOIN public.vendors v ON v.id = w.vendor_id
               WHERE w.id = warehouse_stocks.warehouse_id AND v.user_id = (select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.warehouse_permissions wp
               WHERE wp.warehouse_id = warehouse_stocks.warehouse_id AND wp.user_id = (select auth.uid()))
  )
  WITH CHECK (
    public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.warehouses w JOIN public.vendors v ON v.id = w.vendor_id
               WHERE w.id = warehouse_stocks.warehouse_id AND v.user_id = (select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.warehouse_permissions wp
               WHERE wp.warehouse_id = warehouse_stocks.warehouse_id AND wp.user_id = (select auth.uid()) AND wp.can_manage_stock = true)
  );

DROP POLICY IF EXISTS "Vendors can manage their warehouse permissions" ON public.warehouse_permissions;
DROP POLICY IF EXISTS "Users can view their own permissions" ON public.warehouse_permissions;
CREATE POLICY "warehouse_permissions_select" ON public.warehouse_permissions
  FOR SELECT TO authenticated
  USING (
    user_id = (select auth.uid())
    OR public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.warehouses w JOIN public.vendors v ON v.id = w.vendor_id
               WHERE w.id = warehouse_permissions.warehouse_id AND v.user_id = (select auth.uid()))
  );
CREATE POLICY "warehouse_permissions_owner_manage" ON public.warehouse_permissions
  FOR ALL TO authenticated
  USING (
    public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.warehouses w JOIN public.vendors v ON v.id = w.vendor_id
               WHERE w.id = warehouse_permissions.warehouse_id AND v.user_id = (select auth.uid()))
  )
  WITH CHECK (
    public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.warehouses w JOIN public.vendors v ON v.id = w.vendor_id
               WHERE w.id = warehouse_permissions.warehouse_id AND v.user_id = (select auth.uid()))
  );

DROP POLICY IF EXISTS "Authorized users can create stock movements" ON public.stock_movements;
DROP POLICY IF EXISTS "Vendors can view their stock movements" ON public.stock_movements;
CREATE POLICY "stock_movements_owner_select" ON public.stock_movements
  FOR SELECT TO authenticated
  USING (
    created_by = (select auth.uid())
    OR public.is_admin_or_pdg((select auth.uid()))
    OR EXISTS (SELECT 1 FROM public.products p JOIN public.vendors v ON v.id = p.vendor_id
               WHERE p.id = stock_movements.product_id AND v.user_id = (select auth.uid()))
  );
CREATE POLICY "stock_movements_owner_insert" ON public.stock_movements
  FOR INSERT TO authenticated
  WITH CHECK (
    created_by = (select auth.uid())
    OR EXISTS (SELECT 1 FROM public.products p JOIN public.vendors v ON v.id = p.vendor_id
               WHERE p.id = stock_movements.product_id AND v.user_id = (select auth.uid()))
  );

SELECT 'Palier 3e-2 OK : services pro scopés (catalogue=public read+prestataire write ; staff/stock=prestataire ; réservations/inscriptions/memberships/visites/RDV/bookings=prestataire+client) + entrepôt (warehouse_stocks/permissions/stock_movements via warehouses.vendor_id + warehouse_permissions). LOT 3e TERMINÉ.' AS status;
