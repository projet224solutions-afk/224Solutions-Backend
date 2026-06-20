-- ============================================================================
-- ↩️ Remboursement POS = remet le stock (atomique + idempotent).
--
-- Avant : « Rembourser » faisait juste UPDATE orders SET payment_status='refunded'
-- → le STOCK des articles retournés n'était JAMAIS remis. Et pour une vente cash
-- (table pos_sales), l'UPDATE orders ne matchait même pas.
--
-- Ici : un RPC qui, dans une transaction, marque la vente remboursée ET réincrémente
-- le stock de chaque article. Gère les 2 cas (orders source='pos' ET pos_sales).
-- Idempotent : si déjà remboursé, on NE re-restocke PAS (anti double-restock).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.refund_pos_order_atomic(p_id uuid, p_vendor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_order     public.orders%ROWTYPE;
  v_sale      public.pos_sales%ROWTYPE;
  v_item      record;
  v_restocked int := 0;
BEGIN
  -- Propriété : le vendeur doit posséder la boutique (sauf appel service_role).
  IF auth.uid() IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.vendors v WHERE v.id = p_vendor_id AND v.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'NOT_OWNER';
  END IF;

  -- ── Cas 1 : commande POS électronique (orders) ──
  SELECT * INTO v_order FROM public.orders WHERE id = p_id AND vendor_id = p_vendor_id FOR UPDATE;
  IF FOUND THEN
    IF v_order.payment_status = 'refunded' THEN
      RETURN jsonb_build_object('success', true, 'already_refunded', true);
    END IF;
    FOR v_item IN SELECT product_id, quantity FROM public.order_items WHERE order_id = p_id LOOP
      IF v_item.product_id IS NOT NULL AND COALESCE(v_item.quantity, 0) > 0 THEN
        UPDATE public.products
           SET stock_quantity = COALESCE(stock_quantity, 0) + v_item.quantity, updated_at = now()
         WHERE id = v_item.product_id;
        v_restocked := v_restocked + 1;
      END IF;
    END LOOP;
    UPDATE public.orders
       SET payment_status = 'refunded', status = 'cancelled', updated_at = now()
     WHERE id = p_id;
    RETURN jsonb_build_object('success', true, 'type', 'order', 'restocked', v_restocked);
  END IF;

  -- ── Cas 2 : vente POS cash (pos_sales) ──
  SELECT * INTO v_sale FROM public.pos_sales WHERE id = p_id AND vendor_id = p_vendor_id FOR UPDATE;
  IF FOUND THEN
    IF v_sale.status = 'refunded' THEN
      RETURN jsonb_build_object('success', true, 'already_refunded', true);
    END IF;
    FOR v_item IN SELECT product_id, quantity FROM public.pos_sale_items WHERE pos_sale_id = p_id LOOP
      IF v_item.product_id IS NOT NULL AND COALESCE(v_item.quantity, 0) > 0 THEN
        UPDATE public.products
           SET stock_quantity = COALESCE(stock_quantity, 0) + v_item.quantity, updated_at = now()
         WHERE id = v_item.product_id;
        v_restocked := v_restocked + 1;
      END IF;
    END LOOP;
    UPDATE public.pos_sales SET status = 'refunded' WHERE id = p_id;
    RETURN jsonb_build_object('success', true, 'type', 'pos_sale', 'restocked', v_restocked);
  END IF;

  RAISE EXCEPTION 'NOT_FOUND';
END;
$$;

REVOKE ALL ON FUNCTION public.refund_pos_order_atomic(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refund_pos_order_atomic(uuid, uuid) TO authenticated, service_role;

SELECT 'RPC refund_pos_order_atomic créé (remboursement POS + restock atomique, orders & pos_sales, idempotent).' AS status;
