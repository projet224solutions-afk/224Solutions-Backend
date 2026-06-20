-- Désactiver le trigger qui cause le double décrément du stock
-- Le stock est déjà géré par decrement_stock_on_order_items sur order_items
-- et synchronisé via les triggers bidirectionnels products <-> inventory

DROP TRIGGER IF EXISTS update_inventory_on_order_completion ON orders;

-- Ajouter un commentaire pour documenter la raison
COMMENT ON FUNCTION update_inventory_on_sale() IS 'DEPRECATED - Cette fonction n''est plus utilisée. Le stock est géré par decrement_stock_on_order_items et les triggers de synchronisation bidirectionnelle.';