
-- ============================================================
-- P0 OPTIMIZATION: Batch Stock RPCs + create_order_core
-- ============================================================

-- 1. BATCH DECREMENT: Decrement stock for multiple products in one call
-- Input: JSON array of {product_id, quantity}
-- Returns: JSON array of {product_id, success, old_stock, new_stock, error}
-- Atomic: all-or-nothing with stock validation
CREATE OR REPLACE FUNCTION public.decrement_stock_batch(
  p_items jsonb
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
  results jsonb := '[]'::jsonb;
  has_error boolean := false;
BEGIN
  -- First pass: validate all stock levels
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    product_id := (item->>'product_id')::uuid;
    quantity := (item->>'quantity')::int;
    
    SELECT stock_quantity INTO current_stock
    FROM products
    WHERE id = product_id AND is_active = true
    FOR UPDATE;  -- Row-level lock for concurrency safety
    
    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', format('Product %s not found or inactive', product_id),
        'failed_product_id', product_id
      );
    END IF;
    
    IF current_stock IS NOT NULL AND current_stock < quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', format('Insufficient stock for product %s: %s available, %s requested', product_id, current_stock, quantity),
        'failed_product_id', product_id,
        'available', current_stock,
        'requested', quantity
      );
    END IF;
  END LOOP;
  
  -- Second pass: apply all decrements (safe because we validated + locked)
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    product_id := (item->>'product_id')::uuid;
    quantity := (item->>'quantity')::int;
    
    UPDATE products
    SET stock_quantity = GREATEST(0, COALESCE(stock_quantity, 0) - quantity),
        updated_at = now()
    WHERE id = product_id;
    
    results := results || jsonb_build_object(
      'product_id', product_id,
      'decremented', quantity
    );
  END LOOP;
  
  RETURN jsonb_build_object('success', true, 'items', results);
END;
$$;

COMMENT ON FUNCTION public.decrement_stock_batch IS 'Atomic batch stock decrement with validation. All-or-nothing.';

-- 2. BATCH INCREMENT: Restore stock for multiple products in one call
CREATE OR REPLACE FUNCTION public.increment_stock_batch(
  p_items jsonb
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
  results jsonb := '[]'::jsonb;
BEGIN
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    product_id := (item->>'product_id')::uuid;
    quantity := (item->>'quantity')::int;
    
    UPDATE products
    SET stock_quantity = COALESCE(stock_quantity, 0) + quantity,
        updated_at = now()
    WHERE id = product_id;
    
    IF NOT FOUND THEN
      RAISE WARNING 'Product % not found for stock increment', product_id;
    END IF;
    
    results := results || jsonb_build_object(
      'product_id', product_id,
      'incremented', quantity
    );
  END LOOP;
  
  RETURN jsonb_build_object('success', true, 'items', results);
END;
$$;

COMMENT ON FUNCTION public.increment_stock_batch IS 'Batch stock increment for cancellations/returns.';

-- 3. CREATE ORDER CORE: Single DB call for order + items + stock + escrow
-- Replaces 4 sequential calls with 1 atomic transaction
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
  item_records jsonb := '[]'::jsonb;
BEGIN
  -- ====== PHASE 1: Validate all products + lock rows ======
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
    
    -- Accumulate item data for insert
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
  
  -- ====== PHASE 2: Create order ======
  INSERT INTO orders (
    order_number, customer_id, vendor_id, status, 
    payment_status, payment_method, payment_intent_id,
    subtotal, total_amount, shipping_address, currency
  ) VALUES (
    p_order_number, p_customer_id, p_vendor_id, 'pending',
    CASE WHEN p_payment_method = 'cod' THEN 'pending' ELSE 'processing' END,
    p_payment_method, p_payment_intent_id,
    subtotal, subtotal, p_shipping_address, p_currency
  )
  RETURNING id INTO order_id;
  
  -- ====== PHASE 3: Insert order items ======
  INSERT INTO order_items (order_id, product_id, product_name, quantity, unit_price, total_price, variant_id)
  SELECT 
    order_id,
    (r->>'product_id')::uuid,
    r->>'product_name',
    (r->>'quantity')::int,
    (r->>'unit_price')::numeric,
    (r->>'total_price')::numeric,
    NULLIF(r->>'variant_id', '')::uuid
  FROM jsonb_array_elements(item_records) AS r;
  
  -- ====== PHASE 4: Decrement stock (all at once) ======
  UPDATE products p
  SET stock_quantity = GREATEST(0, COALESCE(p.stock_quantity, 0) - (r->>'quantity')::int),
      updated_at = now()
  FROM jsonb_array_elements(item_records) AS r
  WHERE p.id = (r->>'product_id')::uuid;
  
  -- ====== PHASE 5: Create escrow ======
  INSERT INTO escrow_transactions (
    order_id, buyer_id, seller_id, amount, currency,
    status, auto_release_at, payment_method
  ) VALUES (
    order_id, p_customer_id, p_vendor_user_id, subtotal, p_currency,
    'held', now() + (p_auto_release_days || ' days')::interval, p_payment_method
  );
  
  -- ====== SUCCESS ======
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
  -- Transaction automatically rolls back
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM
  );
END;
$$;

COMMENT ON FUNCTION public.create_order_core IS 'Atomic order creation: validates stock, creates order+items, decrements stock, creates escrow in single transaction.';
