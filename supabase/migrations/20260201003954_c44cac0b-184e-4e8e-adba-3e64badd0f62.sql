
-- Fonction pour décrémenter le stock lors d'une insertion dans order_items
CREATE OR REPLACE FUNCTION public.decrement_stock_on_order_items()
RETURNS TRIGGER AS $$
BEGIN
  -- Mettre à jour le stock du produit (empêcher les valeurs négatives)
  UPDATE products 
  SET stock_quantity = GREATEST(0, stock_quantity - NEW.quantity),
      updated_at = NOW()
  WHERE id = NEW.product_id;

  -- Mettre à jour l'inventaire si un enregistrement existe
  UPDATE inventory 
  SET quantity = GREATEST(0, quantity - NEW.quantity),
      updated_at = NOW()
  WHERE product_id = NEW.product_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Trigger qui s'exécute après chaque insertion dans order_items
DROP TRIGGER IF EXISTS trigger_decrement_stock_on_order_items ON order_items;
CREATE TRIGGER trigger_decrement_stock_on_order_items
AFTER INSERT ON order_items
FOR EACH ROW
EXECUTE FUNCTION decrement_stock_on_order_items();

-- Corriger le stock de "Lait Mana" (soustraire les 5 ventes passées)
UPDATE products 
SET stock_quantity = stock_quantity - 5
WHERE id = 'c2087c1d-806a-47d1-91ae-7653d2eea7c2';

UPDATE inventory 
SET quantity = quantity - 5
WHERE product_id = 'c2087c1d-806a-47d1-91ae-7653d2eea7c2';
