-- D'abord, supprimer les anciens triggers s'ils existent
DROP TRIGGER IF EXISTS sync_inventory_to_products_trigger ON inventory;
DROP TRIGGER IF EXISTS sync_products_to_inventory_trigger ON products;
DROP FUNCTION IF EXISTS sync_inventory_to_product_stock();
DROP FUNCTION IF EXISTS sync_product_stock_to_inventory();

-- Supprimer les doublons dans inventory (garder l'entrée avec la plus grande quantité)
DELETE FROM inventory a
USING inventory b
WHERE a.product_id = b.product_id 
  AND a.id > b.id;

-- Ajouter la contrainte unique sur product_id si elle n'existe pas
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint 
    WHERE conname = 'inventory_product_id_unique'
  ) THEN
    ALTER TABLE inventory ADD CONSTRAINT inventory_product_id_unique UNIQUE (product_id);
  END IF;
END $$;

-- Fonction de synchronisation inventory -> products
CREATE OR REPLACE FUNCTION sync_inventory_to_product_stock()
RETURNS TRIGGER AS $$
BEGIN
  -- Mettre à jour le stock_quantity du produit quand inventory change
  UPDATE products 
  SET stock_quantity = NEW.quantity,
      updated_at = now()
  WHERE id = NEW.product_id;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Trigger pour synchroniser inventory -> products
CREATE TRIGGER sync_inventory_to_products_trigger
AFTER INSERT OR UPDATE OF quantity ON inventory
FOR EACH ROW
EXECUTE FUNCTION sync_inventory_to_product_stock();

-- Fonction de synchronisation products -> inventory
CREATE OR REPLACE FUNCTION sync_product_stock_to_inventory()
RETURNS TRIGGER AS $$
BEGIN
  -- Mettre à jour ou créer l'entrée inventory quand product.stock_quantity change
  INSERT INTO inventory (product_id, quantity, minimum_stock, reserved_quantity, last_updated)
  VALUES (NEW.id, NEW.stock_quantity, COALESCE(NEW.low_stock_threshold, 10), 0, now())
  ON CONFLICT (product_id) 
  DO UPDATE SET 
    quantity = EXCLUDED.quantity,
    last_updated = now()
  WHERE inventory.quantity != EXCLUDED.quantity;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Trigger pour synchroniser products -> inventory
CREATE TRIGGER sync_products_to_inventory_trigger
AFTER INSERT OR UPDATE OF stock_quantity ON products
FOR EACH ROW
EXECUTE FUNCTION sync_product_stock_to_inventory();

-- SYNCHRONISATION INITIALE: Mettre à jour tous les produits avec leurs stocks inventory
UPDATE products p
SET stock_quantity = (SELECT i.quantity FROM inventory i WHERE i.product_id = p.id LIMIT 1),
    updated_at = now()
WHERE EXISTS (SELECT 1 FROM inventory i WHERE i.product_id = p.id AND i.quantity IS DISTINCT FROM p.stock_quantity);

-- SYNCHRONISATION INITIALE: Créer les entrées inventory manquantes pour les produits existants
INSERT INTO inventory (product_id, quantity, minimum_stock, reserved_quantity, last_updated)
SELECT p.id, p.stock_quantity, COALESCE(p.low_stock_threshold, 10), 0, now()
FROM products p
WHERE NOT EXISTS (SELECT 1 FROM inventory i WHERE i.product_id = p.id)
ON CONFLICT (product_id) DO NOTHING;