-- =======================================================================
-- FIX: Décrémenter le stock pour les ventes POS
-- =======================================================================
-- Problème: Le stock ne diminue pas lors des ventes POS car:
-- 1. update_inventory_on_order_trigger (sur order_items) a été supprimé
-- 2. update_inventory_on_order_completion (sur orders) ne se déclenche que sur UPDATE
-- 3. Les ventes POS créent directement les commandes avec status='completed' (INSERT)
--
-- Solution: Créer un trigger sur order_items qui décrémente le stock pour les commandes POS
-- =======================================================================

-- Fonction pour décrémenter le stock lors de l'insertion d'un order_item
CREATE OR REPLACE FUNCTION public.decrement_inventory_on_order_item()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_status TEXT;
  v_order_source TEXT;
BEGIN
  -- Récupérer le status et la source de la commande
  SELECT status, source INTO v_order_status, v_order_source
  FROM orders
  WHERE id = NEW.order_id;

  -- Décrémenter le stock seulement si la commande est déjà complétée/processing
  -- (pour éviter de décrémenter pour les commandes en attente)
  IF v_order_status IN ('completed', 'processing', 'confirmed') THEN

    -- Décrémenter le stock dans inventory
    UPDATE inventory
    SET quantity = GREATEST(0, quantity - NEW.quantity),
        last_updated = NOW()
    WHERE product_id = NEW.product_id
      AND (variant_id = NEW.variant_id OR (variant_id IS NULL AND NEW.variant_id IS NULL));

    -- Si aucune ligne n'a été mise à jour, créer une entrée inventory
    IF NOT FOUND THEN
      INSERT INTO inventory (product_id, variant_id, quantity, reserved_quantity)
      VALUES (NEW.product_id, NEW.variant_id, 0, 0)
      ON CONFLICT (product_id, COALESCE(variant_id, '00000000-0000-0000-0000-000000000000'::UUID))
      DO NOTHING;
    END IF;

    -- Synchroniser products.stock_quantity
    UPDATE products
    SET stock_quantity = (
      SELECT COALESCE(quantity, 0)
      FROM inventory
      WHERE product_id = NEW.product_id
        AND (variant_id = NEW.variant_id OR (variant_id IS NULL AND NEW.variant_id IS NULL))
      LIMIT 1
    )
    WHERE id = NEW.product_id;

  END IF;

  RETURN NEW;
END;
$$;

-- Créer le trigger sur order_items
DROP TRIGGER IF EXISTS decrement_inventory_on_order_item_trigger ON order_items;
CREATE TRIGGER decrement_inventory_on_order_item_trigger
  AFTER INSERT ON order_items
  FOR EACH ROW
  EXECUTE FUNCTION public.decrement_inventory_on_order_item();

COMMENT ON FUNCTION public.decrement_inventory_on_order_item() IS
'Décrémente le stock dans inventory et products.stock_quantity quand un order_item est créé pour une commande complétée/processing/confirmed (POS)';
