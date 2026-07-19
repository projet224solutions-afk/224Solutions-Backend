-- ============================================================================
-- B2B — « Annuler le reliquat » : retour de l'écart au STOCK VENDABLE du fournisseur
--
-- Contexte : à l'expédition, la quantité COMMANDÉE ENTIÈRE quitte le fournisseur
-- (reserved_quantity -= qté ; stock_quantity déjà décrémenté à la confirmation).
-- Si l'acheteur ne reçoit qu'une partie et décide d'ANNULER le reliquat, la
-- marchandise non reçue est réputée non expédiée / retournée → elle redevient
-- vendable chez le fournisseur : stock_quantity += écart, par ligne, via
-- stock_purchase_items.supplier_product_id (le produit du fournisseur est connu).
--
-- L'ARGENT n'est PAS touché ici : il a déjà été réconcilié au reçu par
-- receive_b2b_purchase(close=true) (acheteur remboursé de l'écart selon le mode).
-- Cette RPC ne fait QUE le retour physique + la trace + les infos de notification.
-- Idempotente (drapeau reception_report.reliquat_released).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.b2b_release_reliquat_to_supplier(
  p_purchase_id uuid,
  p_buyer_vendor_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_purchase public.stock_purchases;
  v_supplier_vendor uuid;
  v_supplier_user uuid;
  v_order_number text;
  v_item RECORD;
  v_gap int;
  v_prev int;
  v_total int := 0;
  v_lines jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_purchase FROM public.stock_purchases
  WHERE id = p_purchase_id AND vendor_id = p_buyer_vendor_id AND linked_order_id IS NOT NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FOUND');
  END IF;

  -- La réception doit être CLÔTURÉE (received) : l'argent est déjà réglé au reçu.
  IF v_purchase.status <> 'received' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_purchase.status);
  END IF;

  -- Idempotence : déjà libéré → succès no-op.
  IF COALESCE((v_purchase.reception_report->>'reliquat_released')::boolean, false) THEN
    RETURN jsonb_build_object('success', true, 'already_released', true, 'released', 0);
  END IF;

  -- Fournisseur (vendor + user) via la commande liée, pour le journal et la notif.
  SELECT o.vendor_id, o.order_number INTO v_supplier_vendor, v_order_number
  FROM public.orders o WHERE o.id = v_purchase.linked_order_id;
  IF v_supplier_vendor IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_ORDER_NOT_FOUND');
  END IF;
  SELECT user_id INTO v_supplier_user FROM public.vendors WHERE id = v_supplier_vendor;

  -- Retour de l'écart au stock VENDABLE du fournisseur, ligne à ligne.
  FOR v_item IN
    SELECT id, product_name, supplier_product_id, quantity, received_quantity
    FROM public.stock_purchase_items
    WHERE purchase_id = p_purchase_id
      AND quantity > received_quantity
      AND supplier_product_id IS NOT NULL
  LOOP
    v_gap := v_item.quantity - v_item.received_quantity;
    SELECT stock_quantity INTO v_prev FROM public.products WHERE id = v_item.supplier_product_id FOR UPDATE;
    IF v_prev IS NULL THEN CONTINUE; END IF;

    UPDATE public.products
    SET stock_quantity = stock_quantity + v_gap, updated_at = now()
    WHERE id = v_item.supplier_product_id;

    INSERT INTO public.inventory_history
      (product_id, vendor_id, movement_type, quantity_change, previous_quantity, new_quantity, order_id, notes)
    VALUES
      (v_item.supplier_product_id, v_supplier_vendor, 'return', v_gap, v_prev, v_prev + v_gap,
       v_purchase.linked_order_id,
       'Reliquat B2B annulé par l''acheteur — retour au stock vendable (' || COALESCE(v_purchase.purchase_number, '') || ')');

    v_total := v_total + v_gap;
    v_lines := v_lines || jsonb_build_object(
      'product_id', v_item.supplier_product_id, 'product_name', v_item.product_name,
      'released', v_gap, 'previous_stock', v_prev, 'new_stock', v_prev + v_gap);
  END LOOP;

  -- Trace (qui/quand/quoi) dans reception_report.
  UPDATE public.stock_purchases
  SET reception_report = COALESCE(reception_report, '{}'::jsonb) || jsonb_build_object(
        'reliquat_released', true,
        'reliquat_released_at', now(),
        'reliquat_released_by', p_buyer_vendor_id,
        'reliquat_released_total', v_total,
        'reliquat_released_lines', v_lines),
      updated_at = now()
  WHERE id = p_purchase_id;

  RETURN jsonb_build_object(
    'success', true, 'released', v_total, 'lines', v_lines,
    'supplier_vendor_id', v_supplier_vendor, 'supplier_user_id', v_supplier_user,
    'order_number', v_order_number, 'purchase_number', v_purchase.purchase_number);
END $function$;

REVOKE ALL ON FUNCTION public.b2b_release_reliquat_to_supplier(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.b2b_release_reliquat_to_supplier(uuid, uuid) TO service_role;
