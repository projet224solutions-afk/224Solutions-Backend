
-- Corriger le trigger de décrémentation pour éviter la cascade
-- Le trigger decrement_stock_on_order_items met à jour products ET inventory
-- Mais ensuite sync_inventory_to_product_stock re-synchronise, causant des décrémentations multiples

-- Solution: Le trigger de décrémentation doit UNIQUEMENT mettre à jour products
-- et laisser le trigger sync_product_stock_to_inventory synchroniser vers inventory

CREATE OR REPLACE FUNCTION decrement_stock_on_order_items()
RETURNS TRIGGER AS $$
BEGIN
  -- Mettre à jour UNIQUEMENT le stock du produit (empêcher les valeurs négatives)
  -- Le trigger sync_product_stock_to_inventory synchronisera automatiquement vers inventory
  UPDATE products 
  SET stock_quantity = GREATEST(0, stock_quantity - NEW.quantity),
      updated_at = NOW()
  WHERE id = NEW.product_id;

  -- NE PAS mettre à jour inventory directement ici
  -- car cela cause une cascade avec les triggers de synchronisation bidirectionnelle

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Désactiver temporairement le trigger de sync inventory->products pour éviter les boucles
-- lors de la synchronisation products->inventory
CREATE OR REPLACE FUNCTION sync_product_stock_to_inventory()
RETURNS TRIGGER AS $$
BEGIN
  -- Ne synchroniser que si le stock a vraiment changé
  IF OLD.stock_quantity IS DISTINCT FROM NEW.stock_quantity THEN
    -- Désactiver temporairement le trigger inverse pour éviter la boucle
    ALTER TABLE inventory DISABLE TRIGGER sync_inventory_to_products_trigger;
    
    INSERT INTO inventory (product_id, quantity, minimum_stock, reserved_quantity, last_updated)
    VALUES (NEW.id, NEW.stock_quantity, COALESCE(NEW.low_stock_threshold, 10), 0, now())
    ON CONFLICT (product_id) 
    DO UPDATE SET 
      quantity = EXCLUDED.quantity,
      last_updated = now();
    
    -- Réactiver le trigger
    ALTER TABLE inventory ENABLE TRIGGER sync_inventory_to_products_trigger;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Même chose pour le trigger inverse
CREATE OR REPLACE FUNCTION sync_inventory_to_product_stock()
RETURNS TRIGGER AS $$
BEGIN
  -- Ne synchroniser que si la quantité a vraiment changé
  IF OLD.quantity IS DISTINCT FROM NEW.quantity THEN
    -- Désactiver temporairement le trigger inverse pour éviter la boucle
    ALTER TABLE products DISABLE TRIGGER sync_products_to_inventory_trigger;
    
    UPDATE products 
    SET stock_quantity = NEW.quantity,
        updated_at = now()
    WHERE id = NEW.product_id;
    
    -- Réactiver le trigger
    ALTER TABLE products ENABLE TRIGGER sync_products_to_inventory_trigger;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
