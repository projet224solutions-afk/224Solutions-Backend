-- =======================================================================
-- NETTOYAGE GLOBAL: Appliquer la correction à TOUS les vendeurs
-- =======================================================================

-- 1. Nettoyer reserved_quantity pour TOUS les vendeurs (non utilisé par POS)
UPDATE inventory
SET reserved_quantity = 0
WHERE reserved_quantity != 0;

-- 2. Synchroniser products.stock_quantity depuis inventory pour TOUS les produits
UPDATE products p
SET stock_quantity = COALESCE(i.quantity, 0),
    updated_at = now()
FROM inventory i
WHERE i.product_id = p.id
  AND p.stock_quantity != i.quantity;

-- 3. S'assurer que le trigger reste désactivé (redondant mais sécuritaire)
DROP TRIGGER IF EXISTS update_inventory_on_order_trigger ON order_items;