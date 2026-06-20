-- =======================================================================
-- FONCTION RPC POUR DÉCRÉMENTER LE STOCK DE MANIÈRE FIABLE
-- =======================================================================
-- Cette fonction décrémente directement le stock dans products.stock_quantity
-- Elle est appelée explicitement par le POS pour garantir que le stock diminue
-- =======================================================================

CREATE OR REPLACE FUNCTION public.decrement_product_stock(
  p_product_id UUID,
  p_quantity INTEGER
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Décrémenter le stock dans la table products
  UPDATE products
  SET stock_quantity = GREATEST(0, stock_quantity - p_quantity),
      updated_at = NOW()
  WHERE id = p_product_id;

  -- Le trigger sync_products_to_inventory_trigger synchronisera automatiquement
  -- avec la table inventory si elle existe

  -- Log pour debugging (optionnel)
  RAISE NOTICE 'Stock décrémenté: product_id=%, quantity=-%', p_product_id, p_quantity;
END;
$$;

COMMENT ON FUNCTION public.decrement_product_stock(UUID, INTEGER) IS
'Décrémente le stock dun produit de manière fiable. Appelé par le POS après chaque vente.';

-- Accorder les permissions
GRANT EXECUTE ON FUNCTION public.decrement_product_stock(UUID, INTEGER) TO authenticated;
