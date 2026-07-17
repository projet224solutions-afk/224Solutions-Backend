-- ============================================================================
-- 🏪 ESPACE GROSSISTE 224 — Bloc 1 : FONDATIONS COCKPIT FOURNISSEUR
-- ----------------------------------------------------------------------------
-- Compagnon d'APPROVISIONNEMENT 224 (côté acheteur) : CE bloc donne au
-- FOURNISSEUR ses briques : (1) voir ses CRÉANCES (miroir des dettes — la RLS
-- actuelle de supplier_debts ne couvre que le DÉBITEUR), (2) des TARIFS B2B
-- par client et par palier de quantité (aucun mécanisme n'existait — le B2B
-- lisait uniquement products.price), (3) le moteur de commande B2B applique
-- automatiquement ces tarifs.
-- Prérequis : 20260717150000 / 160000 / 170000 (Approvisionnement 224).
-- ============================================================================

-- 1) ── Créances : le fournisseur LIÉ voit les dettes dont il est créancier ──
-- supplier_debts.vendor_id = DÉBITEUR (acheteur) ; le créancier est le vendeur
-- lié de la fiche fournisseur (vendor_suppliers.linked_vendor_id).
DROP POLICY IF EXISTS supplier_debts_creditor ON public.supplier_debts;
CREATE POLICY supplier_debts_creditor ON public.supplier_debts
  FOR SELECT TO authenticated
  USING (
    supplier_id IN (
      SELECT vs.id
      FROM public.vendor_suppliers vs
      JOIN public.vendors v ON v.id = vs.linked_vendor_id
      WHERE v.user_id = auth.uid() AND vs.link_status = 'linked'
    )
  );

-- 2) ── Tarifs B2B par client (et paliers de quantité) ───────────────────────
CREATE TABLE IF NOT EXISTS public.b2b_client_prices (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  client_vendor_id   uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  product_id         uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  price              numeric NOT NULL CHECK (price >= 0),
  min_quantity       integer NOT NULL DEFAULT 1 CHECK (min_quantity >= 1),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (supplier_vendor_id <> client_vendor_id),
  UNIQUE (supplier_vendor_id, client_vendor_id, product_id, min_quantity)
);
CREATE INDEX IF NOT EXISTS idx_b2b_client_prices_lookup
  ON public.b2b_client_prices (supplier_vendor_id, client_vendor_id, product_id);

ALTER TABLE public.b2b_client_prices ENABLE ROW LEVEL SECURITY;
-- Le FOURNISSEUR gère ses grilles ; le CLIENT voit les siennes (lecture).
DROP POLICY IF EXISTS b2b_client_prices_supplier ON public.b2b_client_prices;
CREATE POLICY b2b_client_prices_supplier ON public.b2b_client_prices
  FOR ALL TO authenticated
  USING (supplier_vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()))
  WITH CHECK (
    supplier_vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    -- Le produit tarifé doit appartenir au fournisseur.
    AND product_id IN (SELECT p.id FROM public.products p
                       WHERE p.vendor_id = supplier_vendor_id)
  );
DROP POLICY IF EXISTS b2b_client_prices_client ON public.b2b_client_prices;
CREATE POLICY b2b_client_prices_client ON public.b2b_client_prices
  FOR SELECT TO authenticated
  USING (client_vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()));

-- Helper : MEILLEUR prix pour (fournisseur, client, produit, quantité).
-- Palier le plus élevé satisfait, sinon NULL (l'appelant retombe sur products.price).
CREATE OR REPLACE FUNCTION public.b2b_client_price_for(
  p_supplier_vendor_id uuid, p_client_vendor_id uuid, p_product_id uuid, p_quantity integer
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT price FROM public.b2b_client_prices
  WHERE supplier_vendor_id = p_supplier_vendor_id
    AND client_vendor_id = p_client_vendor_id
    AND product_id = p_product_id
    AND min_quantity <= GREATEST(COALESCE(p_quantity, 1), 1)
  ORDER BY min_quantity DESC
  LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.b2b_client_price_for(uuid, uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.b2b_client_price_for(uuid, uuid, uuid, integer) TO authenticated, service_role;

-- 3) ── create_b2b_purchase_order v2 : applique le tarif client ─────────────
-- Reprend 20260717160000 À L'IDENTIQUE, sauf : le prix de ligne devient
-- COALESCE(tarif client par palier, products.price).
CREATE OR REPLACE FUNCTION public.create_b2b_purchase_order(
  p_buyer_vendor_id uuid, p_supplier_row_id uuid, p_items jsonb,
  p_payment_mode text, p_payment_timing text,
  p_customer_id uuid,
  p_notes text DEFAULT NULL,
  p_wallet_debit_amount numeric DEFAULT 0, p_buyer_wallet_currency text DEFAULT NULL,
  p_buyer_fee_amount numeric DEFAULT 0, p_currency text DEFAULT 'GNF',
  p_due_date date DEFAULT NULL, p_minimum_installment numeric DEFAULT 0
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_supplier record; v_supplier_vendor record; v_buyer record;
  v_item jsonb; v_product record; v_subtotal numeric := 0;
  v_order_id uuid; v_purchase_id uuid; v_order_number text;
  v_lines jsonb := '[]'::jsonb; v_qty int; v_unit_price numeric;
  v_buyer_user uuid; v_wallet_cur text; v_total_debit numeric; v_bal numeric;
  v_pdg_user uuid; v_fee_res jsonb; v_release_at timestamptz;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMPTY_ITEMS');
  END IF;
  IF p_payment_mode NOT IN ('wallet','cash','credit') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PAYMENT_MODE');
  END IF;
  IF p_payment_timing NOT IN ('on_order','on_reception') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PAYMENT_TIMING');
  END IF;
  IF p_payment_mode <> 'wallet' AND p_payment_timing = 'on_order' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PAYMENT_TIMING');
  END IF;

  SELECT * INTO v_supplier FROM public.vendor_suppliers
  WHERE id = p_supplier_row_id AND vendor_id = p_buyer_vendor_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_NOT_FOUND'); END IF;
  IF v_supplier.link_status <> 'linked' OR v_supplier.linked_vendor_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_NOT_LINKED');
  END IF;

  SELECT id, user_id, business_name INTO v_supplier_vendor
  FROM public.vendors WHERE id = v_supplier.linked_vendor_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_VENDOR_GONE'); END IF;

  SELECT id, user_id, business_name INTO v_buyer
  FROM public.vendors WHERE id = p_buyer_vendor_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'BUYER_VENDOR_NOT_FOUND'); END IF;
  v_buyer_user := v_buyer.user_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_qty := COALESCE((v_item->>'quantity')::int, 0);
    IF v_qty <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
    END IF;
    SELECT p.id, p.name, p.price, p.stock_quantity INTO v_product
    FROM public.products p
    WHERE p.id = (v_item->>'product_id')::uuid
      AND p.vendor_id = v_supplier.linked_vendor_id AND p.is_active = true
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND',
        'product_id', v_item->>'product_id');
    END IF;
    IF v_lines @> jsonb_build_array(jsonb_build_object('product_id', v_product.id::text)) THEN
      RETURN jsonb_build_object('success', false, 'error', 'DUPLICATE_LINE', 'product_name', v_product.name);
    END IF;
    IF COALESCE(v_product.stock_quantity, 0) < v_qty THEN
      RETURN jsonb_build_object('success', false, 'error', 'STOCK_INSUFFICIENT',
        'product_name', v_product.name, 'available', COALESCE(v_product.stock_quantity, 0));
    END IF;
    -- 💰 TARIF CLIENT : palier le plus favorable pour cette quantité, sinon prix public.
    v_unit_price := COALESCE(
      public.b2b_client_price_for(v_supplier.linked_vendor_id, p_buyer_vendor_id, v_product.id, v_qty),
      v_product.price, 0);
    v_subtotal := v_subtotal + (v_unit_price * v_qty);
    v_lines := v_lines || jsonb_build_object(
      'product_id', v_product.id::text, 'product_name', v_product.name,
      'quantity', v_qty, 'unit_price', v_unit_price);
  END LOOP;

  v_order_number := 'B2B-' || to_char(now(), 'YYMMDD') || '-' ||
                    upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  INSERT INTO public.orders (order_number, customer_id, vendor_id, status, payment_status,
    payment_method, subtotal, total_amount, shipping_address, currency, source, order_type, metadata)
  VALUES (v_order_number, p_customer_id, v_supplier.linked_vendor_id, 'pending'::order_status,
    CASE WHEN p_payment_mode = 'wallet' AND p_payment_timing = 'on_order'
         THEN 'paid'::payment_status ELSE 'pending'::payment_status END,
    CASE WHEN p_payment_mode = 'wallet' THEN 'wallet'::payment_method ELSE 'cash'::payment_method END,
    v_subtotal, v_subtotal, '{}'::jsonb, p_currency, 'online'::order_source, 'b2b_purchase',
    jsonb_build_object('b2b', true, 'buyer_vendor_id', p_buyer_vendor_id,
      'buyer_business_name', v_buyer.business_name,
      'payment_mode', p_payment_mode, 'payment_timing', p_payment_timing))
  RETURNING id INTO v_order_id;

  INSERT INTO public.order_items (order_id, product_id, product_name, quantity, unit_price, total_price)
  SELECT v_order_id, (l->>'product_id')::uuid, l->>'product_name', (l->>'quantity')::int,
         (l->>'unit_price')::numeric, (l->>'unit_price')::numeric * (l->>'quantity')::int
  FROM jsonb_array_elements(v_lines) AS l;

  INSERT INTO public.stock_purchases (vendor_id, purchase_number, status, notes, supplier_id,
    payment_mode, payment_timing, currency, due_date, minimum_installment,
    linked_order_id, b2b_buyer_fee, is_locked)
  VALUES (p_buyer_vendor_id, v_order_number, 'ordered', p_notes, p_supplier_row_id,
    p_payment_mode, p_payment_timing, p_currency, p_due_date, COALESCE(p_minimum_installment, 0),
    v_order_id, COALESCE(p_buyer_fee_amount, 0), true)
  RETURNING id INTO v_purchase_id;

  INSERT INTO public.stock_purchase_items (purchase_id, supplier_id, supplier_product_id,
    product_name, quantity, purchase_price, selling_price)
  SELECT v_purchase_id, p_supplier_row_id, (l->>'product_id')::uuid, l->>'product_name',
         (l->>'quantity')::int, (l->>'unit_price')::numeric, (l->>'unit_price')::numeric
  FROM jsonb_array_elements(v_lines) AS l;

  UPDATE public.orders SET metadata = metadata || jsonb_build_object('purchase_id', v_purchase_id)
  WHERE id = v_order_id;

  IF p_payment_mode = 'wallet' AND p_payment_timing = 'on_order' THEN
    v_wallet_cur := COALESCE(p_buyer_wallet_currency, p_currency);
    v_total_debit := COALESCE(p_wallet_debit_amount, 0) + COALESCE(p_buyer_fee_amount, 0);
    IF COALESCE(p_wallet_debit_amount, 0) <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_WALLET_AMOUNT');
    END IF;

    SELECT balance INTO v_bal FROM public.wallets
    WHERE user_id = v_buyer_user AND currency = v_wallet_cur FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'WALLET_NOT_FOUND', 'currency', v_wallet_cur);
    END IF;
    IF v_bal < v_total_debit THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_FUNDS',
        'balance', v_bal, 'required', v_total_debit);
    END IF;

    UPDATE public.wallets SET balance = balance - v_total_debit, updated_at = now()
    WHERE user_id = v_buyer_user AND currency = v_wallet_cur;

    INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
      transaction_type, amount, net_amount, currency, description, status, metadata)
    VALUES ('b2b-' || left(replace(gen_random_uuid()::text, '-', ''), 45), v_buyer_user,
      v_supplier_vendor.user_id, 'payment', p_wallet_debit_amount, p_wallet_debit_amount,
      v_wallet_cur, 'Paiement commande fournisseur B2B — fonds bloqués en escrow', 'completed',
      jsonb_build_object('order_id', v_order_id, 'purchase_id', v_purchase_id,
        'order_currency', p_currency, 'wallet_currency', v_wallet_cur,
        'product_amount', v_subtotal, 'total_debited', v_total_debit,
        'buyer_fee_amount', COALESCE(p_buyer_fee_amount, 0), 'source', 'create_b2b_purchase_order'));

    v_release_at := now() + interval '30 days';
    INSERT INTO public.escrow_transactions (
      order_id, buyer_id, seller_id, payer_id, receiver_id, amount, currency, status,
      auto_release_at, auto_release_date, payment_method, original_amount, original_currency,
      buyer_debit_amount, buyer_debit_currency, exchange_rate_used, is_cross_currency, commission_amount)
    VALUES (v_order_id, v_buyer_user, v_supplier_vendor.user_id, v_buyer_user,
      v_supplier_vendor.user_id, v_subtotal, p_currency, 'held', v_release_at, v_release_at,
      'wallet', v_subtotal, p_currency, p_wallet_debit_amount, v_wallet_cur, NULL,
      (upper(v_wallet_cur) <> upper(p_currency)), 0);

    IF COALESCE(p_buyer_fee_amount, 0) > 0 THEN
      BEGIN
        SELECT user_id INTO v_pdg_user FROM public.pdg_management WHERE is_active = true LIMIT 1;
        IF v_pdg_user IS NOT NULL THEN
          v_fee_res := public.credit_user_wallet_safe(v_pdg_user, p_buyer_fee_amount, v_wallet_cur);
          INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
            transaction_type, amount, net_amount, currency, description, status, metadata)
          VALUES ('fee-' || left(replace(gen_random_uuid()::text, '-', ''), 45), v_buyer_user,
            v_pdg_user, 'commission', p_buyer_fee_amount, p_buyer_fee_amount, v_wallet_cur,
            'Commission acheteur B2B', 'completed',
            jsonb_build_object('order_id', v_order_id, 'purchase_id', v_purchase_id,
              'wallet_currency', v_wallet_cur,
              'pdg_credited', (v_fee_res->>'credited')::numeric, 'pdg_currency', v_fee_res->>'currency',
              'source', 'b2b_buyer_commission'));
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;
  END IF;

  RETURN jsonb_build_object('success', true, 'order_id', v_order_id, 'purchase_id', v_purchase_id,
    'order_number', v_order_number, 'subtotal', v_subtotal, 'currency', p_currency,
    'supplier_user_id', v_supplier_vendor.user_id,
    'supplier_business_name', v_supplier_vendor.business_name,
    'buyer_user_id', v_buyer_user, 'buyer_business_name', v_buyer.business_name,
    'escrow_status', CASE WHEN p_payment_mode = 'wallet' AND p_payment_timing = 'on_order'
                          THEN 'held' ELSE 'none' END);
END;
$$;
REVOKE ALL ON FUNCTION public.create_b2b_purchase_order(uuid, uuid, jsonb, text, text, uuid, text, numeric, text, numeric, text, date, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_b2b_purchase_order(uuid, uuid, jsonb, text, text, uuid, text, numeric, text, numeric, text, date, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_b2b_purchase_order(uuid, uuid, jsonb, text, text, uuid, text, numeric, text, numeric, text, date, numeric) TO service_role;

SELECT 'Grossiste bloc 1 : créances visibles du créancier + tarifs B2B par client/palier + moteur B2B au tarif client.' AS status;
