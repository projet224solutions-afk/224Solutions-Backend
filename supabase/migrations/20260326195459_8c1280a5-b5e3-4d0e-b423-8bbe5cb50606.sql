
-- ============================================================
-- P1 OPTIMIZATION: Atomic POS Sale Complete RPC
-- Combines: idempotence check + pos_sales insert + pos_sale_items insert + stock decrement
-- Reduces 4 DB roundtrips to 1 per sale
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_pos_sale_complete(
  p_vendor_id uuid,
  p_local_sale_id text,
  p_items jsonb,
  p_payment_method text,
  p_total_amount numeric,
  p_discount_total numeric DEFAULT 0,
  p_customer_name text DEFAULT NULL,
  p_customer_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_sold_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  existing_id uuid;
  sale_id uuid;
  item jsonb;
  product_id uuid;
  quantity int;
  current_stock int;
  server_total numeric := 0;
  stock_ok boolean := true;
  stock_error text := '';
  item_record jsonb;
BEGIN
  -- ====== PHASE 1: Idempotence check ======
  SELECT id INTO existing_id
  FROM pos_sales
  WHERE vendor_id = p_vendor_id AND local_sale_id = p_local_sale_id;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'status', 'duplicate',
      'sale_id', existing_id
    );
  END IF;

  -- ====== PHASE 2: Compute server-side total ======
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    server_total := server_total + (
      (item->>'unit_price')::numeric * (item->>'quantity')::int
    ) - COALESCE((item->>'discount')::numeric, 0);
  END LOOP;

  -- ====== PHASE 3: Validate & lock stock ======
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    product_id := (item->>'product_id')::uuid;
    quantity := (item->>'quantity')::int;

    SELECT stock_quantity INTO current_stock
    FROM products
    WHERE id = product_id AND is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
      stock_ok := false;
      stock_error := format('Product %s not found or inactive', product_id);
      EXIT;
    END IF;

    IF current_stock IS NOT NULL AND current_stock < quantity THEN
      stock_ok := false;
      stock_error := format('Insufficient stock for %s: %s available, %s requested', product_id, current_stock, quantity);
      EXIT;
    END IF;
  END LOOP;

  -- ====== PHASE 4: Create pos_sale ======
  INSERT INTO pos_sales (
    vendor_id, local_sale_id, total_amount, discount_total,
    payment_method, customer_name, customer_phone, notes,
    sold_at, synced_at, status, stock_synced
  ) VALUES (
    p_vendor_id, p_local_sale_id, server_total, p_discount_total,
    p_payment_method, p_customer_name, p_customer_phone, p_notes,
    p_sold_at, now(), 'completed', stock_ok
  )
  RETURNING id INTO sale_id;

  -- ====== PHASE 5: Insert pos_sale_items ======
  INSERT INTO pos_sale_items (pos_sale_id, product_id, product_name, quantity, unit_price, discount, total_price)
  SELECT
    sale_id,
    (r->>'product_id')::uuid,
    r->>'product_name',
    (r->>'quantity')::int,
    (r->>'unit_price')::numeric,
    COALESCE((r->>'discount')::numeric, 0),
    ((r->>'unit_price')::numeric * (r->>'quantity')::int) - COALESCE((r->>'discount')::numeric, 0)
  FROM jsonb_array_elements(p_items) AS r;

  -- ====== PHASE 6: Decrement stock (only if validation passed) ======
  IF stock_ok THEN
    UPDATE products p
    SET stock_quantity = GREATEST(0, COALESCE(p.stock_quantity, 0) - (r->>'quantity')::int),
        updated_at = now()
    FROM jsonb_array_elements(p_items) AS r
    WHERE p.id = (r->>'product_id')::uuid;
  ELSE
    -- Create reconciliation entries for failed stock
    INSERT INTO pos_stock_reconciliation (vendor_id, pos_sale_id, product_id, expected_decrement, status, error_message, retry_count, max_retries)
    SELECT
      p_vendor_id,
      sale_id,
      (r->>'product_id')::uuid,
      (r->>'quantity')::int,
      'pending',
      stock_error,
      0,
      5
    FROM jsonb_array_elements(p_items) AS r;
  END IF;

  -- ====== SUCCESS ======
  RETURN jsonb_build_object(
    'status', 'created',
    'sale_id', sale_id,
    'server_total', server_total,
    'stock_synced', stock_ok,
    'stock_error', CASE WHEN stock_ok THEN NULL ELSE stock_error END
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'status', 'error',
    'error', SQLERRM
  );
END;
$$;

COMMENT ON FUNCTION public.create_pos_sale_complete IS 'P1: Atomic POS sale creation. Idempotence + insert sale + items + stock decrement in single transaction. Reduces 4 DB calls to 1.';
