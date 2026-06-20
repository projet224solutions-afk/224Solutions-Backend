-- =====================================================================
-- FIX FINANCE POS hors-ligne : taxe (TVA) calculée SERVER-SIDE + total réel
-- =====================================================================
-- BUG : create_pos_sale_complete stockait pos_sales.total_amount = sous-total
-- (server_total), SANS la taxe ni la remise globale → CA sous-évalué et
-- incohérent avec le POS en ligne (orders) qui, lui, stocke le total taxé.
--
-- CORRECTIF (tout dans la transaction atomique de la RPC) :
--   - sous-total = Σ(unit_price × qté − remise_ligne)  [prix de la caisse vendeur]
--   - taxe = (tax_enabled ? ROUND(sous-total × tax_rate) : 0)  ← depuis pos_settings
--     (TVA CONFIGURABLE par vendeur ; calcul autoritaire côté serveur)
--   - total = GREATEST(0, sous-total + taxe − remise_globale)
--   - on stocke subtotal, tax_amount ET total_amount (aligné sur les commandes).
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

-- 1) Colonnes de cohérence (comme orders : subtotal + tax_amount)
ALTER TABLE public.pos_sales ADD COLUMN IF NOT EXISTS subtotal numeric;
ALTER TABLE public.pos_sales ADD COLUMN IF NOT EXISTS tax_amount numeric DEFAULT 0;

-- Backfill : les ventes existantes ont été enregistrées SANS taxe → subtotal = total
UPDATE public.pos_sales SET subtotal = total_amount WHERE subtotal IS NULL;
UPDATE public.pos_sales SET tax_amount = 0 WHERE tax_amount IS NULL;

-- 2) RPC atomique corrigée (taxe server-side + vrai total)
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
  v_subtotal numeric := 0;
  v_tax numeric := 0;
  v_total numeric := 0;
  v_tax_enabled boolean := false;
  v_tax_rate numeric := 0;
  stock_ok boolean := true;
  stock_error text := '';
BEGIN
  -- ====== PHASE 1: Idempotence ======
  SELECT id INTO existing_id
  FROM pos_sales
  WHERE vendor_id = p_vendor_id AND local_sale_id = p_local_sale_id;

  IF FOUND THEN
    RETURN jsonb_build_object('status', 'duplicate', 'sale_id', existing_id);
  END IF;

  -- ====== PHASE 2: Sous-total (prix caisse) + validation défensive ======
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    IF (item->>'quantity')::int IS NULL OR (item->>'quantity')::int <= 0 THEN
      RETURN jsonb_build_object('status', 'error', 'error', 'Quantité invalide (doit être > 0)');
    END IF;
    IF (item->>'unit_price')::numeric IS NULL OR (item->>'unit_price')::numeric < 0 THEN
      RETURN jsonb_build_object('status', 'error', 'error', 'Prix unitaire invalide (doit être ≥ 0)');
    END IF;
    v_subtotal := v_subtotal + (
      (item->>'unit_price')::numeric * (item->>'quantity')::int
    ) - COALESCE((item->>'discount')::numeric, 0);
  END LOOP;

  -- ====== PHASE 2bis: Taxe SERVER-SIDE depuis pos_settings (configurable) ======
  SELECT COALESCE(tax_enabled, false), COALESCE(tax_rate, 0)
  INTO   v_tax_enabled, v_tax_rate
  FROM   public.pos_settings
  WHERE  vendor_id = p_vendor_id
  LIMIT  1;

  v_tax   := CASE WHEN v_tax_enabled THEN ROUND(v_subtotal * v_tax_rate) ELSE 0 END;
  v_total := GREATEST(0, v_subtotal + v_tax - COALESCE(p_discount_total, 0));

  -- ====== PHASE 3: Valider & verrouiller le stock ======
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    product_id := (item->>'product_id')::uuid;
    quantity := (item->>'quantity')::int;

    SELECT stock_quantity INTO current_stock
    FROM products WHERE id = product_id AND is_active = true FOR UPDATE;

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

  -- ====== PHASE 4: Créer la vente (total taxé) ======
  INSERT INTO pos_sales (
    vendor_id, local_sale_id, subtotal, tax_amount, total_amount, discount_total,
    payment_method, customer_name, customer_phone, notes,
    sold_at, synced_at, status, stock_synced
  ) VALUES (
    p_vendor_id, p_local_sale_id, v_subtotal, v_tax, v_total, p_discount_total,
    p_payment_method, p_customer_name, p_customer_phone, p_notes,
    p_sold_at, now(), 'completed', stock_ok
  )
  RETURNING id INTO sale_id;

  -- ====== PHASE 5: Lignes de vente ======
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

  -- ====== PHASE 6: Décrément stock ======
  IF stock_ok THEN
    UPDATE products p
    SET stock_quantity = GREATEST(0, COALESCE(p.stock_quantity, 0) - (r->>'quantity')::int),
        updated_at = now()
    FROM jsonb_array_elements(p_items) AS r
    WHERE p.id = (r->>'product_id')::uuid;
  ELSE
    INSERT INTO pos_stock_reconciliation (vendor_id, pos_sale_id, product_id, expected_decrement, status, error_message, retry_count, max_retries)
    SELECT p_vendor_id, sale_id, (r->>'product_id')::uuid, (r->>'quantity')::int, 'pending', stock_error, 0, 5
    FROM jsonb_array_elements(p_items) AS r;
  END IF;

  RETURN jsonb_build_object(
    'status', 'created',
    'sale_id', sale_id,
    'subtotal', v_subtotal,
    'tax_amount', v_tax,
    'total', v_total,
    'server_total', v_total,
    'stock_synced', stock_ok,
    'stock_error', CASE WHEN stock_ok THEN NULL ELSE stock_error END
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;
