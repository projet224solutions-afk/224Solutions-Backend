-- Fix marketplace order creation to use the real payment_status enum.
-- The enum only supports pending|paid|failed|refunded, so create_order_core
-- must not insert the legacy text value "processing".

CREATE OR REPLACE FUNCTION public.create_order_core(
  p_order_number text,
  p_customer_id uuid,
  p_vendor_id uuid,
  p_vendor_user_id uuid,
  p_payment_method text,
  p_payment_intent_id text DEFAULT NULL,
  p_shipping_address jsonb DEFAULT '{}'::jsonb,
  p_currency text DEFAULT 'GNF',
  p_items jsonb DEFAULT '[]'::jsonb,
  p_auto_release_days int DEFAULT 7
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item jsonb;
  product_id uuid;
  quantity int;
  current_stock int;
  product_price numeric;
  product_name text;
  subtotal numeric := 0;
  order_id uuid;
  buyer_user_id uuid;
  item_records jsonb := '[]'::jsonb;
BEGIN
  SELECT c.user_id
  INTO buyer_user_id
  FROM customers c
  WHERE c.id = p_customer_id;

  IF buyer_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', format('Customer %s is not linked to an auth user', p_customer_id)
    );
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    product_id := (item->>'product_id')::uuid;
    quantity := (item->>'quantity')::int;

    SELECT p.stock_quantity, p.price, p.name
    INTO current_stock, product_price, product_name
    FROM products p
    WHERE p.id = product_id
      AND p.vendor_id = p_vendor_id
      AND p.is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', format('Product %s not found, inactive, or wrong vendor', product_id)
      );
    END IF;

    IF current_stock IS NOT NULL AND current_stock < quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', format('Insufficient stock for "%s": %s available, %s requested', product_name, current_stock, quantity)
      );
    END IF;

    item_records := item_records || jsonb_build_object(
      'product_id', product_id,
      'product_name', product_name,
      'quantity', quantity,
      'unit_price', product_price,
      'total_price', product_price * quantity,
      'variant_id', item->>'variant_id'
    );

    subtotal := subtotal + (product_price * quantity);
  END LOOP;

  INSERT INTO orders (
    order_number, customer_id, vendor_id, status,
    payment_status, payment_method, payment_intent_id,
    subtotal, total_amount, shipping_address
  ) VALUES (
    p_order_number, p_customer_id, p_vendor_id, 'pending',
    'pending'::payment_status,
    p_payment_method::payment_method, p_payment_intent_id,
    subtotal, subtotal, p_shipping_address
  )
  RETURNING id INTO order_id;

  INSERT INTO order_items (order_id, product_id, quantity, unit_price, total_price, variant_id)
  SELECT
    order_id,
    (r->>'product_id')::uuid,
    (r->>'quantity')::int,
    (r->>'unit_price')::numeric,
    (r->>'total_price')::numeric,
    NULLIF(r->>'variant_id', '')::uuid
  FROM jsonb_array_elements(item_records) AS r;

  UPDATE products p
  SET stock_quantity = GREATEST(0, COALESCE(p.stock_quantity, 0) - (r->>'quantity')::int),
      updated_at = now()
  FROM jsonb_array_elements(item_records) AS r
  WHERE p.id = (r->>'product_id')::uuid;

  INSERT INTO escrow_transactions (
    order_id, buyer_id, seller_id, amount, currency,
    status, auto_release_date
  ) VALUES (
    order_id, buyer_user_id, p_vendor_user_id, subtotal, p_currency,
    'held', (now() + (p_auto_release_days || ' days')::interval)::date
  );

  RETURN jsonb_build_object(
    'success', true,
    'order_id', order_id,
    'order_number', p_order_number,
    'subtotal', subtotal,
    'total_amount', subtotal,
    'currency', p_currency,
    'items', item_records,
    'escrow_status', 'held'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM
  );
END;
$$;