-- ═══════════════════════════════════════════════════════════════════════════════
-- 🔧 CORRECTION DES POLITIQUES RLS POUR LE SYSTÈME D'ENTREPÔT
-- Correction du bug: vendor_id n'est pas auth.uid() mais l'ID de la table vendors
-- 224SOLUTIONS
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. SUPPRIMER LES ANCIENNES POLITIQUES INCORRECTES
-- ═══════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS "Vendors can manage their warehouse stocks" ON public.warehouse_stocks;
DROP POLICY IF EXISTS "Vendors can view their stock movements" ON public.stock_movements;
DROP POLICY IF EXISTS "Vendors can create stock movements for their warehouses" ON public.stock_movements;
DROP POLICY IF EXISTS "Vendors can manage their warehouses" ON public.warehouses;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. CRÉER LES NOUVELLES POLITIQUES CORRIGÉES POUR WAREHOUSES
-- ═══════════════════════════════════════════════════════════════════════════════

-- Vérifier que RLS est activé
ALTER TABLE public.warehouses ENABLE ROW LEVEL SECURITY;

-- Les vendeurs peuvent voir et gérer leurs entrepôts
CREATE POLICY "Vendors can manage their warehouses" ON public.warehouses
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.vendors v 
    WHERE v.id = warehouses.vendor_id 
    AND v.user_id = auth.uid()
  )
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. CRÉER LES NOUVELLES POLITIQUES POUR WAREHOUSE_STOCKS
-- ═══════════════════════════════════════════════════════════════════════════════

-- Les vendeurs peuvent gérer les stocks de leurs entrepôts
CREATE POLICY "Vendors can manage their warehouse stocks" ON public.warehouse_stocks
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.warehouses w 
    JOIN public.vendors v ON v.id = w.vendor_id
    WHERE w.id = warehouse_stocks.warehouse_id 
    AND v.user_id = auth.uid()
  )
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. CRÉER LES NOUVELLES POLITIQUES POUR STOCK_MOVEMENTS
-- ═══════════════════════════════════════════════════════════════════════════════

-- Les vendeurs peuvent voir les mouvements de stock de leurs entrepôts
CREATE POLICY "Vendors can view their stock movements" ON public.stock_movements
FOR SELECT USING (
  (from_warehouse_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.warehouses w 
    JOIN public.vendors v ON v.id = w.vendor_id
    WHERE w.id = stock_movements.from_warehouse_id 
    AND v.user_id = auth.uid()
  )) OR
  (to_warehouse_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.warehouses w 
    JOIN public.vendors v ON v.id = w.vendor_id
    WHERE w.id = stock_movements.to_warehouse_id 
    AND v.user_id = auth.uid()
  ))
);

-- Les vendeurs peuvent créer des mouvements de stock pour leurs entrepôts
CREATE POLICY "Vendors can create stock movements for their warehouses" ON public.stock_movements
FOR INSERT WITH CHECK (
  (from_warehouse_id IS NULL OR EXISTS (
    SELECT 1 FROM public.warehouses w 
    JOIN public.vendors v ON v.id = w.vendor_id
    WHERE w.id = stock_movements.from_warehouse_id 
    AND v.user_id = auth.uid()
  )) AND
  (to_warehouse_id IS NULL OR EXISTS (
    SELECT 1 FROM public.warehouses w 
    JOIN public.vendors v ON v.id = w.vendor_id
    WHERE w.id = stock_movements.to_warehouse_id 
    AND v.user_id = auth.uid()
  ))
);

-- Les vendeurs peuvent modifier/supprimer leurs mouvements de stock
CREATE POLICY "Vendors can update their stock movements" ON public.stock_movements
FOR UPDATE USING (
  (from_warehouse_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.warehouses w 
    JOIN public.vendors v ON v.id = w.vendor_id
    WHERE w.id = stock_movements.from_warehouse_id 
    AND v.user_id = auth.uid()
  )) OR
  (to_warehouse_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.warehouses w 
    JOIN public.vendors v ON v.id = w.vendor_id
    WHERE w.id = stock_movements.to_warehouse_id 
    AND v.user_id = auth.uid()
  ))
);

CREATE POLICY "Vendors can delete their stock movements" ON public.stock_movements
FOR DELETE USING (
  (from_warehouse_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.warehouses w 
    JOIN public.vendors v ON v.id = w.vendor_id
    WHERE w.id = stock_movements.from_warehouse_id 
    AND v.user_id = auth.uid()
  )) OR
  (to_warehouse_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.warehouses w 
    JOIN public.vendors v ON v.id = w.vendor_id
    WHERE w.id = stock_movements.to_warehouse_id 
    AND v.user_id = auth.uid()
  ))
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. INDEX POUR OPTIMISER LES REQUÊTES
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_warehouses_vendor_id ON public.warehouses(vendor_id);
CREATE INDEX IF NOT EXISTS idx_warehouse_stocks_warehouse_id ON public.warehouse_stocks(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_warehouse_stocks_product_id ON public.warehouse_stocks(product_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_from_warehouse ON public.stock_movements(from_warehouse_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_to_warehouse ON public.stock_movements(to_warehouse_id);

-- ═══════════════════════════════════════════════════════════════════════════════
-- COMMENTAIRES
-- ═══════════════════════════════════════════════════════════════════════════════

COMMENT ON POLICY "Vendors can manage their warehouses" ON public.warehouses IS 
  'Permet aux vendeurs de gérer leurs propres entrepôts via jointure vendors.user_id = auth.uid()';
COMMENT ON POLICY "Vendors can manage their warehouse stocks" ON public.warehouse_stocks IS 
  'Permet aux vendeurs de gérer les stocks de leurs entrepôts via jointure vendors.user_id = auth.uid()';
