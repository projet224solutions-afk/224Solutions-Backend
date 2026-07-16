-- ============================================================================
-- FIX enum cast create_pos_order_complete (POS /api/pos/order) — meme famille
-- que le 42804 execute_atomic_deposit (M4). p_payment_method (text) etait insere
-- dans orders.payment_method (enum payment_method) SANS cast explicite -> 409
-- 'column payment_method is of type payment_method but expression is of type text'
-- -> AUCUNE vente POS "order" n'aboutissait. Fix: p_payment_method::payment_method.
-- (p_payment_status et p_status etaient deja castes.) Idempotent (CREATE OR REPLACE).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.create_pos_order_complete(p_vendor_id uuid, p_customer_id uuid, p_order_number text, p_items jsonb, p_payment_method text, p_payment_status text, p_status text, p_discount_total numeric DEFAULT 0, p_notes text DEFAULT NULL::text, p_currency text DEFAULT 'GNF'::text, p_shipping_address jsonb DEFAULT '{"address": "Point de vente"}'::jsonb, p_credit_customer_name text DEFAULT NULL::text, p_credit_customer_phone text DEFAULT NULL::text, p_credit_due_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_credit_notes text DEFAULT NULL::text, p_credit_items jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  item jsonb;
  current_stock int;
  v_qty int;
  v_unit numeric;
  v_subtotal numeric := 0;
  v_tax numeric := 0;
  v_total numeric := 0;
  v_tax_enabled boolean := false;
  v_tax_rate numeric := 0;
  v_order_id uuid;
  v_existing_id uuid;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'Aucun article');
  END IF;

  -- IDEMPOTENCE : order_number est UNIQUE â un retry renvoie la commande existante
  -- (au lieu d'une violation d'unicitÃ©) sans re-dÃ©crÃ©menter le stock.
  SELECT id, total_amount, subtotal, tax_amount INTO v_existing_id, v_total, v_subtotal, v_tax
  FROM orders WHERE order_number = p_order_number LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'status', 'duplicate', 'order_id', v_existing_id, 'order_number', p_order_number,
      'subtotal', v_subtotal, 'tax_amount', v_tax, 'total', v_total
    );
  END IF;
  v_subtotal := 0; v_tax := 0;  -- rÃ©initialiser aprÃ¨s le SELECT idempotence

  -- Sous-total (prix caisse vendeur) + validation dÃ©fensive
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := (item->>'quantity')::int;
    v_unit := (item->>'unit_price')::numeric;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RETURN jsonb_build_object('status', 'error', 'error', 'QuantitÃ© invalide (doit Ãªtre > 0)');
    END IF;
    IF v_unit IS NULL OR v_unit < 0 THEN
      RETURN jsonb_build_object('status', 'error', 'error', 'Prix unitaire invalide (doit Ãªtre â¥ 0)');
    END IF;
    v_subtotal := v_subtotal + (v_unit * v_qty) - COALESCE((item->>'discount')::numeric, 0);
  END LOOP;

  -- Taxe server-side (configurable par vendeur)
  SELECT COALESCE(tax_enabled, false), COALESCE(tax_rate, 0)
  INTO   v_tax_enabled, v_tax_rate
  FROM   public.pos_settings WHERE vendor_id = p_vendor_id LIMIT 1;

  v_tax   := CASE WHEN v_tax_enabled THEN ROUND(v_subtotal * v_tax_rate) ELSE 0 END;
  v_total := GREATEST(0, v_subtotal + v_tax - COALESCE(p_discount_total, 0));

  -- Validation + verrou stock
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    SELECT stock_quantity INTO current_stock
    FROM products WHERE id = (item->>'product_id')::uuid AND is_active = true FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'error', 'error', format('Produit %s introuvable ou inactif', item->>'product_id'));
    END IF;
    IF current_stock IS NOT NULL AND current_stock < (item->>'quantity')::int THEN
      RETURN jsonb_build_object('status', 'error', 'error', format('Stock insuffisant pour %s', item->>'product_id'));
    END IF;
  END LOOP;

  -- Commande (source='pos')
  INSERT INTO orders (
    order_number, vendor_id, customer_id, subtotal, tax_amount, discount_amount,
    total_amount, payment_status, status, payment_method, shipping_address,
    notes, source, currency
  ) VALUES (
    p_order_number, p_vendor_id, p_customer_id, v_subtotal, v_tax, COALESCE(p_discount_total, 0),
    v_total, p_payment_status::payment_status, p_status::order_status, p_payment_method::payment_method, p_shipping_address,
    p_notes, 'pos', p_currency
  )
  RETURNING id INTO v_order_id;

  -- Lignes (le trigger decrement_stock_on_order_items dÃ©crÃ©mente le stock, source='pos')
  INSERT INTO order_items (order_id, product_id, quantity, unit_price, total_price)
  SELECT
    v_order_id,
    (r->>'product_id')::uuid,
    (r->>'quantity')::int,
    (r->>'unit_price')::numeric,
    ((r->>'unit_price')::numeric * (r->>'quantity')::int) - COALESCE((r->>'discount')::numeric, 0)
  FROM jsonb_array_elements(p_items) AS r;

  -- Vente Ã  crÃ©dit : enregistrement vendor_credit_sales dans la MÃME transaction
  IF p_payment_method = 'credit' THEN
    INSERT INTO vendor_credit_sales (
      vendor_id, order_number, customer_name, customer_phone, items,
      subtotal, tax, total, remaining_amount, due_date, notes, status
    ) VALUES (
      p_vendor_id, p_order_number, COALESCE(NULLIF(TRIM(p_credit_customer_name), ''), 'Client'),
      p_credit_customer_phone, COALESCE(p_credit_items, '[]'::jsonb),
      v_subtotal, v_tax, v_total, v_total, COALESCE(p_credit_due_date, now()), p_credit_notes, 'pending'
    );
  END IF;

  RETURN jsonb_build_object(
    'status', 'created',
    'order_id', v_order_id,
    'order_number', p_order_number,
    'subtotal', v_subtotal,
    'tax_amount', v_tax,
    'total', v_total
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$function$
;