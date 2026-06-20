-- ============================================================================
-- 👁️ Lecture des ventes POS (cash) par le vendeur propriétaire.
--
-- Les ventes POS « online/cash » passent par le backend (syncPosSales → pos_sales),
-- table qui n'avait QUE la policy « Service role only ». Résultat : la vue vendeur
-- « Ventes POS » (lecture directe Supabase côté front) ne voyait JAMAIS ces ventes
-- → les ventes du jour étaient invisibles. On autorise le vendeur à LIRE ses propres
-- ventes POS (et leurs lignes). Écriture toujours réservée au service_role (inchangé).
-- ============================================================================

DROP POLICY IF EXISTS pos_sales_vendor_select ON public.pos_sales;
CREATE POLICY pos_sales_vendor_select ON public.pos_sales
  FOR SELECT TO authenticated
  USING (vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()));

DROP POLICY IF EXISTS pos_sale_items_vendor_select ON public.pos_sale_items;
CREATE POLICY pos_sale_items_vendor_select ON public.pos_sale_items
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1
    FROM public.pos_sales s
    JOIN public.vendors v ON v.id = s.vendor_id
    WHERE s.id = pos_sale_items.pos_sale_id
      AND v.user_id = auth.uid()
  ));

SELECT 'RLS : le vendeur peut lire ses pos_sales + pos_sale_items (ventes POS du jour enfin visibles).' AS status;
