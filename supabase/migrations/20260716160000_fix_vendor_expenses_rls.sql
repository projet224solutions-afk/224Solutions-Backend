-- ============================================================================
-- FIX RLS vendor_expenses : la policy exigeait is_vendor_or_agent(vendor_id) qui
-- teste vendors.id = vendor_id, alors que la colonne vendor_id est un FK vers
-- auth.users (= l'auth uid du vendeur). Contradiction : auth uid -> 403 (RLS),
-- vendors.id -> 409 (FK). La creation de depense etait donc IMPOSSIBLE pour tout
-- vendeur. Fix : aligner la policy sur la semantique de la colonne (proprietaire).
-- ============================================================================
DROP POLICY IF EXISTS "Vendors can manage their expenses" ON public.vendor_expenses;
CREATE POLICY "Vendors can manage their expenses" ON public.vendor_expenses
  FOR ALL
  USING (vendor_id = auth.uid())
  WITH CHECK (vendor_id = auth.uid());