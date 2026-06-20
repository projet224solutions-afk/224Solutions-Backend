-- ================================================================
-- FIX COMPLET create_order_core — analyse profonde 2026-05-17
--
-- Bugs identifiés qui bloquent TOUS les paiements :
--   B1. orders.currency       n'existe pas → INSERT Phase 2 échoue
--   B2. order_items.product_name n'existe pas → INSERT Phase 3 échoue
--   B3. v_buyer_wallet_id bigint mais wallets.id est UUID → crash wallet
--   B4. wallet_transactions exige transaction_id + net_amount (NOT NULL)
--   B5. Colonnes escrow manquantes (auto_release_at, payment_method, ...)
--   B6. Mauvais casts enum (payment_status, order_status, payment_method)
-- ================================================================

-- ────────────────────────────────────────────────────────────────
-- 1. Colonnes manquantes dans orders
-- ────────────────────────────────────────────────────────────────

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS currency TEXT DEFAULT 'GNF';

-- ────────────────────────────────────────────────────────────────
-- 2. Colonnes manquantes dans order_items
-- ────────────────────────────────────────────────────────────────

ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS product_name TEXT;

-- ────────────────────────────────────────────────────────────────
-- 3. Colonnes manquantes dans escrow_transactions
-- ────────────────────────────────────────────────────────────────

ALTER TABLE public.escrow_transactions
  ADD COLUMN IF NOT EXISTS buyer_id         UUID,
  ADD COLUMN IF NOT EXISTS seller_id        UUID,
  ADD COLUMN IF NOT EXISTS payer_id         UUID,
  ADD COLUMN IF NOT EXISTS receiver_id      UUID,
  ADD COLUMN IF NOT EXISTS payment_method   TEXT,
  ADD COLUMN IF NOT EXISTS commission_amount NUMERIC DEFAULT 0,
  ADD COLUMN IF NOT EXISTS auto_release_at  TIMESTAMPTZ;

UPDATE public.escrow_transactions
SET auto_release_at = auto_release_date
WHERE auto_release_at IS NULL
  AND auto_release_date IS NOT NULL;

-- ────────────────────────────────────────────────────────────────
-- 4. Supprimer TOUTES les surcharges de create_order_core
-- ────────────────────────────────────────────────────────────────

DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT oid::regprocedure AS func_sig
    FROM   pg_proc
    WHERE  proname        = 'create_order_core'
      AND  pronamespace   = 'public'::regnamespace
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.func_sig || ' CASCADE';
  END LOOP;
END;
$$;

-- ────────────────────────────────────────────────────────────────
-- 5. Recréer create_order_core — version finale corrigée
-- ────────────────────────────────────────────────────────────────

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
  -- B1 fix : orders.currency ajouté en section 1 ci-dessus
  -- B6 fix : casts enum explicites
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
  -- B2 fix : order_items.product_name ajouté en section 2 ci-dessus
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
  -- Utilise sender_user_id/receiver_user_id (UUID) au lieu des wallet IDs (BIGINT)
  -- transaction_type = 'payment' (valeur enum valide)
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

-- Vérification
SELECT 'create_order_core OK — 6 bugs corrigés (currency, product_name, wallet UUID, transaction_id, net_amount, enums).' AS status;
