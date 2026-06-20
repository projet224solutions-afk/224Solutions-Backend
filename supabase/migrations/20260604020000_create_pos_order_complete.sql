-- =====================================================================
-- POS EN LIGNE ATOMIQUE : commande + items + stock + (crédit) en 1 transaction
-- =====================================================================
-- Les paiements POS mobile money / carte / crédit créaient la commande puis
-- les order_items en DEUX appels frontend séparés (non atomique : commande
-- orpheline si l'insert items échoue) + taxe calculée côté client. Le crédit
-- ajoutait EN PLUS un 3e insert frontend dans vendor_credit_sales.
--
-- Cette RPC (appelée par le backend Node.js POST /api/pos/order) fait tout
-- atomiquement : sous-total (prix caisse) + TAXE SERVER-SIDE (pos_settings,
-- configurable) + total, insert commande (source='pos') + order_items, ET pour
-- une vente à crédit l'enregistrement vendor_credit_sales — le tout dans la
-- MÊME transaction. Le stock est décrémenté par le trigger
-- decrement_stock_on_order_items DANS cette transaction (source='pos' → 1 seul
-- décrément).
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

-- DROP défensif de l'ancienne signature (sans les paramètres de crédit), au cas
-- où une version antérieure aurait déjà été créée (évite une surcharge ambiguë).
DROP FUNCTION IF EXISTS public.create_pos_order_complete(
  uuid, uuid, text, jsonb, text, text, text, numeric, text, text, jsonb
);

CREATE OR REPLACE FUNCTION public.create_pos_order_complete(
  p_vendor_id uuid,
  p_customer_id uuid,
  p_order_number text,
  p_items jsonb,
  p_payment_method text,
  p_payment_status text,
  p_status text,
  p_discount_total numeric DEFAULT 0,
  p_notes text DEFAULT NULL,
  p_currency text DEFAULT 'GNF',
  p_shipping_address jsonb DEFAULT '{"address":"Point de vente"}'::jsonb,
  -- Paramètres de vente à crédit (utilisés uniquement si p_payment_method = 'credit')
  p_credit_customer_name text DEFAULT NULL,
  p_credit_customer_phone text DEFAULT NULL,
  p_credit_due_date timestamptz DEFAULT NULL,
  p_credit_notes text DEFAULT NULL,
  p_credit_items jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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

  -- IDEMPOTENCE : order_number est UNIQUE → un retry renvoie la commande existante
  -- (au lieu d'une violation d'unicité) sans re-décrémenter le stock.
  SELECT id, total_amount, subtotal, tax_amount INTO v_existing_id, v_total, v_subtotal, v_tax
  FROM orders WHERE order_number = p_order_number LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'status', 'duplicate', 'order_id', v_existing_id, 'order_number', p_order_number,
      'subtotal', v_subtotal, 'tax_amount', v_tax, 'total', v_total
    );
  END IF;
  v_subtotal := 0; v_tax := 0;  -- réinitialiser après le SELECT idempotence

  -- Sous-total (prix caisse vendeur) + validation défensive
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_qty := (item->>'quantity')::int;
    v_unit := (item->>'unit_price')::numeric;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RETURN jsonb_build_object('status', 'error', 'error', 'Quantité invalide (doit être > 0)');
    END IF;
    IF v_unit IS NULL OR v_unit < 0 THEN
      RETURN jsonb_build_object('status', 'error', 'error', 'Prix unitaire invalide (doit être ≥ 0)');
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
    v_total, p_payment_status::payment_status, p_status::order_status, p_payment_method, p_shipping_address,
    p_notes, 'pos', p_currency
  )
  RETURNING id INTO v_order_id;

  -- Lignes (le trigger decrement_stock_on_order_items décrémente le stock, source='pos')
  INSERT INTO order_items (order_id, product_id, quantity, unit_price, total_price)
  SELECT
    v_order_id,
    (r->>'product_id')::uuid,
    (r->>'quantity')::int,
    (r->>'unit_price')::numeric,
    ((r->>'unit_price')::numeric * (r->>'quantity')::int) - COALESCE((r->>'discount')::numeric, 0)
  FROM jsonb_array_elements(p_items) AS r;

  -- Vente à crédit : enregistrement vendor_credit_sales dans la MÊME transaction
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
$$;
