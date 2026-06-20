-- ============================================================================
-- 🛒 Lien de paiement multi-produits : décrément de stock au paiement.
--
-- Un lien de paiement peut désormais contenir plusieurs produits (metadata.items =
-- [{product_id, name, price, qty, image}]). À la RÉUSSITE du paiement, on décrémente
-- atomiquement le stock de chaque produit. IDEMPOTENT : flag metadata.stock_consumed
-- (+ verrou FOR UPDATE) → un double appel (retry, multi-canal) ne décrémente qu'une fois.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.consume_payment_link_stock(p_link_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_link  public.payment_links%ROWTYPE;
  v_items jsonb;
  v_item  jsonb;
  v_pid   uuid;
  v_qty   numeric;
  v_done  int := 0;
BEGIN
  SELECT * INTO v_link FROM public.payment_links WHERE id = p_link_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'LINK_NOT_FOUND'); END IF;

  -- Idempotent : déjà consommé → on sort
  IF COALESCE((v_link.metadata->>'stock_consumed')::boolean, false) THEN
    RETURN jsonb_build_object('success', true, 'already_consumed', true);
  END IF;

  v_items := COALESCE(v_link.metadata->'items', '[]'::jsonb);

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_pid := NULLIF(v_item->>'product_id', '')::uuid;
    v_qty := COALESCE((v_item->>'qty')::numeric, 1);
    IF v_pid IS NOT NULL AND v_qty > 0 THEN
      UPDATE public.products
         SET stock_quantity = GREATEST(0, COALESCE(stock_quantity, 0) - v_qty),
             updated_at = now()
       WHERE id = v_pid;
      v_done := v_done + 1;
    END IF;
  END LOOP;

  UPDATE public.payment_links
     SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('stock_consumed', true)
   WHERE id = p_link_id;

  RETURN jsonb_build_object('success', true, 'products_updated', v_done);
END;
$$;

REVOKE ALL ON FUNCTION public.consume_payment_link_stock(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.consume_payment_link_stock(uuid) TO service_role;

SELECT 'RPC consume_payment_link_stock créé (décrément stock idempotent au paiement d''un lien multi-produits).' AS status;
