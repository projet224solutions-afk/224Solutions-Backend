
-- FIX: Corriger les politiques deliveries avec les bonnes colonnes

-- Nettoyer les politiques restantes si elles existent
DROP POLICY IF EXISTS "deliveries_select_policy" ON public.deliveries;
DROP POLICY IF EXISTS "deliveries_insert_policy" ON public.deliveries;
DROP POLICY IF EXISTS "deliveries_update_policy" ON public.deliveries;

-- Nouvelle politique: Lecture pour chauffeurs et vendeurs
CREATE POLICY "deliveries_select_policy" ON public.deliveries
  FOR SELECT TO authenticated
  USING (
    driver_id = auth.uid() OR
    client_id = auth.uid() OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

-- Nouvelle politique: Création de livraisons
CREATE POLICY "deliveries_insert_policy" ON public.deliveries
  FOR INSERT TO authenticated
  WITH CHECK (
    client_id = auth.uid() OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

-- Nouvelle politique: Mise à jour par chauffeurs et vendeurs
CREATE POLICY "deliveries_update_policy" ON public.deliveries
  FOR UPDATE TO authenticated
  USING (
    driver_id = auth.uid() OR
    client_id = auth.uid() OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  )
  WITH CHECK (
    driver_id = auth.uid() OR
    client_id = auth.uid() OR
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );
