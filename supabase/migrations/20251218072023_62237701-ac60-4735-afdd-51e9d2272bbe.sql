-- =======================================================================
-- CORRECTION STOCK VND0006 + FIX DOUBLE DÉCRÉMENTATION POS
-- =======================================================================

-- 1. Désactiver le trigger update_inventory_on_order sur order_items
--    Car il ne fait que réserver (reserved_quantity), pas décrémenter le stock réel
--    Et le POS n'utilise pas reserved_quantity de toute façon
DROP TRIGGER IF EXISTS update_inventory_on_order_trigger ON order_items;

-- 2. Recalculer le stock réel pour VND0006 basé sur les ventes POS
-- Calculer le total vendu par produit depuis les order_items pour les commandes POS
WITH vendor AS (
  SELECT id FROM vendors WHERE vendor_code = 'VND0006' LIMIT 1
),
pos_sales AS (
  SELECT 
    oi.product_id,
    SUM(oi.quantity) as total_sold
  FROM order_items oi
  JOIN orders o ON o.id = oi.order_id
  WHERE o.vendor_id = (SELECT id FROM vendor)
    AND o.source = 'pos'
    AND o.status IN ('confirmed', 'processing', 'completed')
  GROUP BY oi.product_id
),
-- Calculer les ajustements manuels positifs (réapprovisionnements)
manual_adjustments AS (
  SELECT 
    ih.product_id,
    SUM(CASE WHEN ih.quantity_change > 0 THEN ih.quantity_change ELSE 0 END) as total_added
  FROM inventory_history ih
  WHERE ih.vendor_id = (SELECT id FROM vendor)
    AND ih.movement_type = 'adjustment'
    AND ih.quantity_change > 0
  GROUP BY ih.product_id
),
-- Stock initial estimé = dernier réapprovisionnement connu (on prend le max ajouté)
corrected_stock AS (
  SELECT 
    p.id as product_id,
    COALESCE(ma.total_added, 0) as stock_added,
    COALESCE(ps.total_sold, 0) as stock_sold,
    GREATEST(0, COALESCE(ma.total_added, 0) - COALESCE(ps.total_sold, 0)) as correct_stock
  FROM products p
  LEFT JOIN pos_sales ps ON ps.product_id = p.id
  LEFT JOIN manual_adjustments ma ON ma.product_id = p.id
  WHERE p.vendor_id = (SELECT id FROM vendor)
)
-- Mettre à jour inventory avec le stock corrigé
UPDATE inventory i
SET quantity = cs.correct_stock,
    reserved_quantity = 0,
    last_updated = now()
FROM corrected_stock cs
WHERE i.product_id = cs.product_id;

-- 3. Synchroniser products.stock_quantity depuis inventory
UPDATE products p
SET stock_quantity = i.quantity,
    updated_at = now()
FROM inventory i
WHERE i.product_id = p.id
  AND p.vendor_id = (SELECT id FROM vendors WHERE vendor_code = 'VND0006' LIMIT 1);

-- 4. Nettoyer reserved_quantity pour ce vendeur (non utilisé par POS)
UPDATE inventory i
SET reserved_quantity = 0
FROM products p
WHERE i.product_id = p.id
  AND p.vendor_id = (SELECT id FROM vendors WHERE vendor_code = 'VND0006' LIMIT 1);