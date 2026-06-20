-- =====================================================
-- MIGRATION ENTREPÔTS + CORRECTIF RLS AGENTS
-- 224SOLUTIONS - 02 Mai 2026
-- =====================================================
-- Problèmes corrigés :
--   1. Données de l'ancienne table `warehouses` migrées vers `vendor_locations`
--   2. RLS de toutes les tables entrepôt étendue aux agents (vendor_agents.user_id)
--   3. Set du lieu par défaut pour chaque vendeur sans lieu par défaut
-- =====================================================

BEGIN;

-- =====================================================
-- 1. MIGRATION DONNÉES : warehouses → vendor_locations
-- =====================================================
-- Les vendeurs ont leurs entrepôts dans la table `warehouses` (ancien système).
-- Le nouveau composant lit `vendor_locations`. On migre les données manquantes.

INSERT INTO public.vendor_locations (
  vendor_id,
  name,
  address,
  location_type,
  is_pos_enabled,
  is_active,
  is_default,
  created_at,
  updated_at
)
SELECT
  w.vendor_id,
  w.name,
  w.address,
  'warehouse',
  false,
  COALESCE(w.is_active, true),
  false,
  COALESCE(w.created_at, NOW()),
  COALESCE(w.created_at, NOW())
FROM public.warehouses w
WHERE
  -- Ne pas dupliquer si un lieu avec le même nom existe déjà
  NOT EXISTS (
    SELECT 1
    FROM public.vendor_locations vl
    WHERE vl.vendor_id = w.vendor_id
      AND LOWER(TRIM(vl.name)) = LOWER(TRIM(w.name))
  )
  -- Ne migrer que les vendeurs qui existent dans vendors
  AND EXISTS (
    SELECT 1 FROM public.vendors v WHERE v.id = w.vendor_id
  );

-- Définir le premier entrepôt comme lieu par défaut pour les vendeurs
-- qui n'ont aucun lieu par défaut
UPDATE public.vendor_locations vl
SET is_default = true
WHERE vl.id IN (
  SELECT DISTINCT ON (sub.vendor_id) sub.id
  FROM public.vendor_locations sub
  WHERE sub.location_type = 'warehouse'
    AND sub.vendor_id NOT IN (
      SELECT vendor_id FROM public.vendor_locations WHERE is_default = true
    )
  ORDER BY sub.vendor_id, sub.created_at ASC
);

-- =====================================================
-- 2. RLS : vendor_locations — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can manage their locations" ON public.vendor_locations;
CREATE POLICY "Vendors can manage their locations"
ON public.vendor_locations
FOR ALL USING (
  -- Propriétaire direct (vendeur connecté)
  EXISTS (
    SELECT 1 FROM public.vendors v
    WHERE v.id = vendor_locations.vendor_id
      AND v.user_id = auth.uid()
  )
  OR
  -- Agent du vendeur (avec user_id Supabase Auth)
  EXISTS (
    SELECT 1 FROM public.vendor_agents va
    WHERE va.vendor_id = vendor_locations.vendor_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
  OR
  -- Permission granulaire par lieu
  EXISTS (
    SELECT 1 FROM public.location_permissions lp
    WHERE lp.location_id = vendor_locations.id
      AND lp.user_id = auth.uid()
      AND lp.is_active = TRUE
  )
);

-- =====================================================
-- 3. RLS : location_stock — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can manage location stock" ON public.location_stock;
CREATE POLICY "Vendors can manage location stock"
ON public.location_stock
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendors v ON v.id = vl.vendor_id
    WHERE vl.id = location_stock.location_id
      AND v.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendor_agents va ON va.vendor_id = vl.vendor_id
    WHERE vl.id = location_stock.location_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
  OR
  EXISTS (
    SELECT 1 FROM public.location_permissions lp
    WHERE lp.location_id = location_stock.location_id
      AND lp.user_id = auth.uid()
      AND lp.is_active = TRUE
  )
);

-- =====================================================
-- 4. RLS : stock_transfers — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can manage their transfers" ON public.stock_transfers;
CREATE POLICY "Vendors can manage their transfers"
ON public.stock_transfers
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.vendors v
    WHERE v.id = stock_transfers.vendor_id
      AND v.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM public.vendor_agents va
    WHERE va.vendor_id = stock_transfers.vendor_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
);

-- =====================================================
-- 5. RLS : stock_transfer_items — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can view their transfer items" ON public.stock_transfer_items;
CREATE POLICY "Vendors can view their transfer items"
ON public.stock_transfer_items
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.stock_transfers st
    JOIN public.vendors v ON v.id = st.vendor_id
    WHERE st.id = stock_transfer_items.transfer_id
      AND v.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM public.stock_transfers st
    JOIN public.vendor_agents va ON va.vendor_id = st.vendor_id
    WHERE st.id = stock_transfer_items.transfer_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
);

-- =====================================================
-- 6. RLS : stock_losses — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can manage their losses" ON public.stock_losses;
CREATE POLICY "Vendors can manage their losses"
ON public.stock_losses
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.vendors v
    WHERE v.id = stock_losses.vendor_id
      AND v.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM public.vendor_agents va
    WHERE va.vendor_id = stock_losses.vendor_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
);

-- =====================================================
-- 7. RLS : location_stock_history — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can view stock history" ON public.location_stock_history;
CREATE POLICY "Vendors can view stock history"
ON public.location_stock_history
FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendors v ON v.id = vl.vendor_id
    WHERE vl.id = location_stock_history.location_id
      AND v.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendor_agents va ON va.vendor_id = vl.vendor_id
    WHERE vl.id = location_stock_history.location_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
);

-- =====================================================
-- 8. RLS : location_permissions — ajouter les agents
-- =====================================================

DROP POLICY IF EXISTS "Vendors can manage location permissions" ON public.location_permissions;
CREATE POLICY "Vendors can manage location permissions"
ON public.location_permissions
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendors v ON v.id = vl.vendor_id
    WHERE vl.id = location_permissions.location_id
      AND v.user_id = auth.uid()
  )
  OR
  EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendor_agents va ON va.vendor_id = vl.vendor_id
    WHERE vl.id = location_permissions.location_id
      AND va.user_id = auth.uid()
      AND va.is_active = TRUE
  )
  OR location_permissions.user_id = auth.uid()
);

COMMIT;
