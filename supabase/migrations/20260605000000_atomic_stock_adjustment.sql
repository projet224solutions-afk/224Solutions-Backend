-- =====================================================================
-- AJUSTEMENT DE STOCK ATOMIQUE (anti lost-update)
-- =====================================================================
-- BUG : /api/inventory/adjust lisait products.stock_quantity, calculait
-- old + adjustment en JS, puis écrivait le résultat → entre la lecture et
-- l'écriture, une commande concurrente (ou un 2e ajustement) pouvait modifier
-- le stock → MISE À JOUR PERDUE (lost update) → stock faux.
--
-- CORRECTIF : cette RPC verrouille la ligne produit (FOR UPDATE) → sérialise
-- l'ajustement avec les décréments de commande (qui font UPDATE products) et les
-- autres ajustements. Garde anti-négatif + écriture de l'historique dans la MÊME
-- transaction. Le miroir `inventory` est mis à jour par le trigger
-- sync_product_inventory (migration 20260604000000).
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.adjust_product_stock_atomic(
  p_product_id uuid,
  p_vendor_id uuid,
  p_adjustment int,
  p_reason text,
  p_notes text,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old int;
  v_new int;
BEGIN
  IF p_adjustment IS NULL OR p_adjustment = 0 THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'Ajustement nul');
  END IF;

  -- Verrou de ligne : sérialise avec les décréments de commande et autres ajustements
  SELECT COALESCE(stock_quantity, 0) INTO v_old
  FROM products
  WHERE id = p_product_id AND vendor_id = p_vendor_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'Produit non trouvé ou non autorisé');
  END IF;

  v_new := v_old + p_adjustment;
  IF v_new < 0 THEN
    RETURN jsonb_build_object(
      'status', 'error', 'old_stock', v_old,
      'error', format('Stock résultant négatif (%s + %s = %s)', v_old, p_adjustment, v_new)
    );
  END IF;

  UPDATE products SET stock_quantity = v_new, updated_at = now() WHERE id = p_product_id;

  INSERT INTO inventory_history (
    product_id, vendor_id, change_type, quantity_change,
    old_quantity, new_quantity, reason, notes, performed_by
  ) VALUES (
    p_product_id, p_vendor_id,
    CASE WHEN p_adjustment > 0 THEN 'addition' ELSE 'subtraction' END,
    abs(p_adjustment), v_old, v_new, p_reason, p_notes, p_user_id
  );

  RETURN jsonb_build_object('status', 'success', 'old_stock', v_old, 'new_stock', v_new);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;

-- Réservé au backend (service_role) — défense en profondeur (SECURITY DEFINER)
REVOKE ALL ON FUNCTION public.adjust_product_stock_atomic(uuid, uuid, int, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.adjust_product_stock_atomic(uuid, uuid, int, text, text, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.adjust_product_stock_atomic(uuid, uuid, int, text, text, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_product_stock_atomic(uuid, uuid, int, text, text, uuid) TO service_role;
