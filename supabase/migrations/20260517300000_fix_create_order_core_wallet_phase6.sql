-- ================================================================
-- FIX PHASE 6 create_order_core — 2026-05-17
--
-- Bugs dans la version précédente (20260517100000) :
--   Bug A : v_buyer_wallet_id déclaré UUID mais wallets.id est BIGSERIAL (BIGINT)
--           → SELECT id INTO uuid_var depuis wallets échoue → crash
--   Bug B : transaction_type = 'marketplace_purchase' n'est pas dans l'enum
--           → valeurs valides : 'payment', 'transfer', 'deposit', etc.
--
-- Solution :
--   - Supprimer v_buyer_wallet_id (plus utilisé)
--   - Utiliser sender_user_id / receiver_user_id (UUID) au lieu des wallet IDs BIGINT
--   - Changer 'marketplace_purchase' → 'payment'
-- ================================================================

-- Supprimer toutes les surcharges existantes
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT oid::regprocedure AS func_sig
    FROM   pg_proc
    WHERE  proname      = 'create_order_core'
      AND  pronamespace = 'public'::regnamespace
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.func_sig || ' CASCADE';
  END LOOP;
END;
$$;

CREATE FUNCTION public.create_order_core(
  p_order_number        text,
  p_customer_id         uuid,
  p_vendor_id           uuid,
  p_vendor_user_id      uuid,
  p_payment_method      text,
  p_payment_intent_id   text    DEFAULT NULL,
  p_shipping_address    jsonb   DEFAULT '{}'::jsonb,
  p_currency            text    DEFAULT 'GNF',
  p_items               jsonb   DEFAULT '[]'::jsonb,
  p_auto_release_days   int     DEFAULT 7,
  p_buyer_user_id       uuid    DEFAULT NULL,
  p_wallet_debit_amount numeric DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item             jsonb;
  v_product_id     uuid;
  v_quantity       int;
  v_current_stock  int;
  v_product_price  numeric;
  v_product_name   text;
  v_subtotal       numeric := 0;
  v_order_id       uuid;
  v_item_records   jsonb   := '[]'::jsonb;
  v_release_at     timestamptz;
BEGIN

  -- ── PHASE 0 : Vérification solde wallet ──────────────────────
  IF p_payment_method = 'wallet'
     AND p_buyer_user_id IS NOT NULL
     AND p_wallet_debit_amount > 0
  THEN
    PERFORM 1
    FROM public.wallets
    WHERE user_id = p_buyer_user_id
      AND balance >= p_wallet_debit_amount
    FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   'Solde wallet insuffisant pour effectuer cet achat'
      );
    END IF;
  END IF;

  -- ── PHASE 1 : Valider les produits ───────────────────────────
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (item->>'product_id')::uuid;
    v_quantity   := (item->>'quantity')::int;

    SELECT p.stock_quantity, p.price, p.name
    INTO   v_current_stock, v_product_price, v_product_name
    FROM   products p
    WHERE  p.id        = v_product_id
      AND  p.vendor_id = p_vendor_id
      AND  p.is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   format('Produit %s introuvable, inactif ou mauvais vendeur', v_product_id)
      );
    END IF;

    IF v_current_stock IS NOT NULL AND v_current_stock < v_quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   format('Stock insuffisant pour "%s" : %s disponible, %s demandé',
                          v_product_name, v_current_stock, v_quantity)
      );
    END IF;

    v_item_records := v_item_records || jsonb_build_object(
      'product_id',   v_product_id,
      'product_name', v_product_name,
      'quantity',     v_quantity,
      'unit_price',   v_product_price,
      'total_price',  v_product_price * v_quantity,
      'variant_id',   item->>'variant_id'
    );

    v_subtotal := v_subtotal + (v_product_price * v_quantity);
  END LOOP;

  -- ── PHASE 2 : Créer la commande ──────────────────────────────
  INSERT INTO orders (
    order_number, customer_id, vendor_id, status,
    payment_status, payment_method, payment_intent_id,
    subtotal, total_amount, shipping_address, currency
  ) VALUES (
    p_order_number, p_customer_id, p_vendor_id,
    'pending'::order_status,
    'pending'::payment_status,
    p_payment_method::payment_method,
    p_payment_intent_id,
    v_subtotal, v_subtotal, p_shipping_address, p_currency
  )
  RETURNING id INTO v_order_id;

  -- ── PHASE 3 : Lignes de commande ─────────────────────────────
  INSERT INTO order_items (
    order_id, product_id, product_name,
    quantity, unit_price, total_price, variant_id
  )
  SELECT
    v_order_id,
    (r->>'product_id')::uuid,
    r->>'product_name',
    (r->>'quantity')::int,
    (r->>'unit_price')::numeric,
    (r->>'total_price')::numeric,
    NULLIF(r->>'variant_id', '')::uuid
  FROM jsonb_array_elements(v_item_records) AS r;

  -- ── PHASE 4 : Décrémenter le stock ───────────────────────────
  UPDATE products p
  SET    stock_quantity = GREATEST(0, COALESCE(p.stock_quantity, 0) - (r->>'quantity')::int),
         updated_at     = now()
  FROM   jsonb_array_elements(v_item_records) AS r
  WHERE  p.id = (r->>'product_id')::uuid;

  -- ── PHASE 5 : Créer l'escrow ─────────────────────────────────
  v_release_at := now() + (p_auto_release_days || ' days')::interval;

  INSERT INTO escrow_transactions (
    order_id, buyer_id, seller_id, payer_id, receiver_id,
    amount, currency, status,
    auto_release_at, auto_release_date, payment_method
  ) VALUES (
    v_order_id,
    p_customer_id,
    p_vendor_user_id,
    p_buyer_user_id,
    p_vendor_user_id,
    v_subtotal, p_currency, 'held',
    v_release_at, v_release_at,
    p_payment_method
  );

  -- ── PHASE 6 : Débit wallet atomique ──────────────────────────
  -- Fix A : utilise sender_user_id/receiver_user_id (UUID) au lieu de
  --         sender_wallet_id/receiver_wallet_id (BIGINT) → évite le cast UUID↔BIGINT
  -- Fix B : 'payment' est une valeur enum transaction_type valide
  IF p_payment_method = 'wallet'
     AND p_buyer_user_id IS NOT NULL
     AND p_wallet_debit_amount > 0
  THEN
    UPDATE public.wallets
    SET    balance    = balance - p_wallet_debit_amount,
           updated_at = now()
    WHERE  user_id = p_buyer_user_id;

    INSERT INTO public.wallet_transactions (
      transaction_id,
      sender_user_id,
      receiver_user_id,
      transaction_type,
      amount,
      net_amount,
      description,
      status,
      metadata
    ) VALUES (
      'mkt-' || left(replace(gen_random_uuid()::text, '-', ''), 45),
      p_buyer_user_id,
      p_vendor_user_id,
      'payment',
      p_wallet_debit_amount,
      p_wallet_debit_amount,
      'Paiement commande marketplace — Fonds bloqués en Escrow',
      'completed',
      jsonb_build_object(
        'order_id',       v_order_id,
        'currency',       p_currency,
        'product_amount', v_subtotal,
        'total_debited',  p_wallet_debit_amount,
        'source',         'create_order_core'
      )
    );
  END IF;

  -- ── SUCCESS ──────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'success',      true,
    'order_id',     v_order_id,
    'order_number', p_order_number,
    'subtotal',     v_subtotal,
    'total_amount', v_subtotal,
    'currency',     p_currency,
    'items',        v_item_records,
    'escrow_status','held'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error',   SQLERRM
  );
END;
$$;

SELECT 'create_order_core Phase 6 corrigé — wallet UUID→user_id + payment_method enum valide.' AS status;
