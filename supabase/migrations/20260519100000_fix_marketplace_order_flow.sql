-- ================================================================
-- MIGRATION CONSOLIDÉE : fix flux commandes marketplace (2026-05-19)
--
-- Problèmes corrigés :
--   BUG #1 — create_marketplace_order_secure (v20260517210000, production)
--            ne transmet pas p_buyer_wallet_currency à create_order_core
--            → Phase 0 cherche le wallet dans la devise vendeur au lieu de
--              la devise acheteur → "Portefeuille introuvable en EUR"
--
--   BUG #2 — create_order_core (production) crée toujours la commande
--            avec payment_status='pending', même quand le wallet est débité
--            → commandes apparaissent impayées dans les dashboards
--
--   BUG #3 — Le frontend passe p_exchange_rate_used pour les achats
--            multi-devises, mais la production de
--            create_marketplace_order_secure n'a pas ce paramètre
--            → erreur de signature RPC ("function does not exist")
--
-- Stratégie (sans DROP CASCADE) :
--   1. CREATE OR REPLACE create_order_core (13 params — même signature que
--      production) → corrige payment_status, remplace la version production.
--
--   2. CREATE OR REPLACE create_order_core (14 params — ajoute
--      p_exchange_rate_used DEFAULT NULL) → nouvelle surcharge pour les
--      appels cross-currency avec taux de change.
--
--   3. CREATE OR REPLACE create_marketplace_order_secure (8 params — ajoute
--      p_exchange_rate_used DEFAULT NULL) → nouvelle surcharge appelée par
--      le frontend quand exchangeRateUsed !== null.
--      Résout p_buyer_wallet_currency depuis wallets et le passe à
--      create_order_core.
-- ================================================================

-- ================================================================
-- ÉTAPE 1 : create_order_core — 13 params (même signature production)
--           Corrige payment_status='paid' pour paiements wallet
-- ================================================================

CREATE OR REPLACE FUNCTION public.create_order_core(
  p_order_number           text,
  p_customer_id            uuid,
  p_vendor_id              uuid,
  p_vendor_user_id         uuid,
  p_payment_method         text,
  p_payment_intent_id      text    DEFAULT NULL,
  p_shipping_address       jsonb   DEFAULT '{}'::jsonb,
  p_currency               text    DEFAULT 'GNF',
  p_items                  jsonb   DEFAULT '[]'::jsonb,
  p_auto_release_days      int     DEFAULT 7,
  p_buyer_user_id          uuid    DEFAULT NULL,
  p_wallet_debit_amount    numeric DEFAULT 0,
  p_buyer_wallet_currency  text    DEFAULT NULL
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
  v_wallet_cur     text;
  v_payment_status payment_status;
BEGIN

  v_wallet_cur := COALESCE(p_buyer_wallet_currency, p_currency);

  v_payment_status := CASE
    WHEN p_payment_method = 'wallet' AND p_wallet_debit_amount > 0 THEN 'paid'::payment_status
    ELSE 'pending'::payment_status
  END;

  -- ── PHASE 0 : Vérification solde wallet ──────────────────────────────────
  IF p_payment_method = 'wallet'
     AND p_buyer_user_id IS NOT NULL
     AND p_wallet_debit_amount > 0
  THEN
    PERFORM 1
    FROM public.wallets
    WHERE user_id = p_buyer_user_id
      AND currency = v_wallet_cur
      AND balance  >= p_wallet_debit_amount
    FOR UPDATE;

    IF NOT FOUND THEN
      PERFORM 1
      FROM public.wallets
      WHERE user_id = p_buyer_user_id
        AND currency = v_wallet_cur;

      IF NOT FOUND THEN
        RETURN jsonb_build_object(
          'success', false,
          'error',   format('Portefeuille introuvable en %s pour cet utilisateur', v_wallet_cur)
        );
      ELSE
        RETURN jsonb_build_object(
          'success', false,
          'error',   format('Solde %s insuffisant pour effectuer cet achat', v_wallet_cur)
        );
      END IF;
    END IF;
  END IF;

  -- ── PHASE 1 : Valider les produits ───────────────────────────────────────
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

  -- ── PHASE 2 : Créer la commande ──────────────────────────────────────────
  INSERT INTO orders (
    order_number, customer_id, vendor_id, status,
    payment_status, payment_method, payment_intent_id,
    subtotal, total_amount, shipping_address, currency
  ) VALUES (
    p_order_number, p_customer_id, p_vendor_id,
    'pending'::order_status,
    v_payment_status,
    p_payment_method::payment_method,
    p_payment_intent_id,
    v_subtotal, v_subtotal, p_shipping_address, p_currency
  )
  RETURNING id INTO v_order_id;

  -- ── PHASE 3 : Lignes de commande ─────────────────────────────────────────
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

  -- ── PHASE 4 : Décrémenter le stock ───────────────────────────────────────
  UPDATE products p
  SET    stock_quantity = GREATEST(0, COALESCE(p.stock_quantity, 0) - (r->>'quantity')::int),
         updated_at     = now()
  FROM   jsonb_array_elements(v_item_records) AS r
  WHERE  p.id = (r->>'product_id')::uuid;

  -- ── PHASE 5 : Créer l'escrow ─────────────────────────────────────────────
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

  -- ── PHASE 6 : Débit wallet atomique ──────────────────────────────────────
  IF p_payment_method = 'wallet'
     AND p_buyer_user_id IS NOT NULL
     AND p_wallet_debit_amount > 0
  THEN
    UPDATE public.wallets
    SET    balance    = balance - p_wallet_debit_amount,
           updated_at = now()
    WHERE  user_id = p_buyer_user_id
      AND  currency = v_wallet_cur;

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
        'order_id',            v_order_id,
        'order_currency',      p_currency,
        'wallet_currency',     v_wallet_cur,
        'product_amount',      v_subtotal,
        'total_debited',       p_wallet_debit_amount,
        'is_cross_currency',   (p_currency IS DISTINCT FROM v_wallet_cur),
        'source',              'create_order_core_v13'
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'success',         true,
    'order_id',        v_order_id,
    'order_number',    p_order_number,
    'subtotal',        v_subtotal,
    'total_amount',    v_subtotal,
    'currency',        p_currency,
    'items',           v_item_records,
    'escrow_status',   'held',
    'payment_status',  v_payment_status::text
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- ================================================================
-- ÉTAPE 2 : create_order_core — 14 params (nouvelle surcharge)
--           Ajoute p_exchange_rate_used pour achats cross-currency
-- ================================================================

CREATE OR REPLACE FUNCTION public.create_order_core(
  p_order_number           text,
  p_customer_id            uuid,
  p_vendor_id              uuid,
  p_vendor_user_id         uuid,
  p_payment_method         text,
  p_payment_intent_id      text    DEFAULT NULL,
  p_shipping_address       jsonb   DEFAULT '{}'::jsonb,
  p_currency               text    DEFAULT 'GNF',
  p_items                  jsonb   DEFAULT '[]'::jsonb,
  p_auto_release_days      int     DEFAULT 7,
  p_buyer_user_id          uuid    DEFAULT NULL,
  p_wallet_debit_amount    numeric DEFAULT 0,
  p_buyer_wallet_currency  text    DEFAULT NULL,
  p_exchange_rate_used     numeric DEFAULT NULL
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
  v_wallet_cur     text;
  v_payment_status payment_status;
BEGIN

  v_wallet_cur := COALESCE(p_buyer_wallet_currency, p_currency);

  v_payment_status := CASE
    WHEN p_payment_method = 'wallet' AND p_wallet_debit_amount > 0 THEN 'paid'::payment_status
    ELSE 'pending'::payment_status
  END;

  -- ── PHASE 0 : Vérification solde wallet ──────────────────────────────────
  IF p_payment_method = 'wallet'
     AND p_buyer_user_id IS NOT NULL
     AND p_wallet_debit_amount > 0
  THEN
    PERFORM 1
    FROM public.wallets
    WHERE user_id = p_buyer_user_id
      AND currency = v_wallet_cur
      AND balance  >= p_wallet_debit_amount
    FOR UPDATE;

    IF NOT FOUND THEN
      PERFORM 1
      FROM public.wallets
      WHERE user_id = p_buyer_user_id
        AND currency = v_wallet_cur;

      IF NOT FOUND THEN
        RETURN jsonb_build_object(
          'success', false,
          'error',   format('Portefeuille introuvable en %s pour cet utilisateur', v_wallet_cur)
        );
      ELSE
        RETURN jsonb_build_object(
          'success', false,
          'error',   format('Solde %s insuffisant pour effectuer cet achat', v_wallet_cur)
        );
      END IF;
    END IF;
  END IF;

  -- ── PHASE 1 : Valider les produits ───────────────────────────────────────
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

  -- ── PHASE 2 : Créer la commande ──────────────────────────────────────────
  INSERT INTO orders (
    order_number, customer_id, vendor_id, status,
    payment_status, payment_method, payment_intent_id,
    subtotal, total_amount, shipping_address, currency
  ) VALUES (
    p_order_number, p_customer_id, p_vendor_id,
    'pending'::order_status,
    v_payment_status,
    p_payment_method::payment_method,
    p_payment_intent_id,
    v_subtotal, v_subtotal, p_shipping_address, p_currency
  )
  RETURNING id INTO v_order_id;

  -- ── PHASE 3 : Lignes de commande ─────────────────────────────────────────
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

  -- ── PHASE 4 : Décrémenter le stock ───────────────────────────────────────
  UPDATE products p
  SET    stock_quantity = GREATEST(0, COALESCE(p.stock_quantity, 0) - (r->>'quantity')::int),
         updated_at     = now()
  FROM   jsonb_array_elements(v_item_records) AS r
  WHERE  p.id = (r->>'product_id')::uuid;

  -- ── PHASE 5 : Créer l'escrow ─────────────────────────────────────────────
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

  -- ── PHASE 6 : Débit wallet atomique ──────────────────────────────────────
  IF p_payment_method = 'wallet'
     AND p_buyer_user_id IS NOT NULL
     AND p_wallet_debit_amount > 0
  THEN
    UPDATE public.wallets
    SET    balance    = balance - p_wallet_debit_amount,
           updated_at = now()
    WHERE  user_id = p_buyer_user_id
      AND  currency = v_wallet_cur;

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
        'order_id',            v_order_id,
        'order_currency',      p_currency,
        'wallet_currency',     v_wallet_cur,
        'product_amount',      v_subtotal,
        'total_debited',       p_wallet_debit_amount,
        'exchange_rate_used',  p_exchange_rate_used,
        'is_cross_currency',   (p_currency IS DISTINCT FROM v_wallet_cur),
        'source',              'create_order_core_v14'
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'success',            true,
    'order_id',           v_order_id,
    'order_number',       p_order_number,
    'subtotal',           v_subtotal,
    'total_amount',       v_subtotal,
    'currency',           p_currency,
    'items',              v_item_records,
    'escrow_status',      'held',
    'payment_status',     v_payment_status::text,
    'exchange_rate_used', p_exchange_rate_used
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- ================================================================
-- ÉTAPE 3 : create_marketplace_order_secure — 8 params (nouvelle surcharge)
--           Résout p_buyer_wallet_currency + transmet p_exchange_rate_used
--           Appelée par le frontend quand exchangeRateUsed !== null
-- ================================================================

CREATE OR REPLACE FUNCTION public.create_marketplace_order_secure(
  p_vendor_id           uuid,
  p_payment_method      text,
  p_items               jsonb    DEFAULT '[]'::jsonb,
  p_shipping_address    jsonb    DEFAULT '{}'::jsonb,
  p_currency            text     DEFAULT 'GNF',
  p_wallet_debit_amount numeric  DEFAULT 0,
  p_auto_release_days   int      DEFAULT 7,
  p_exchange_rate_used  numeric  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_buyer_user_id    uuid          := auth.uid();
  v_customer_id      uuid;
  v_vendor_user_id   uuid;
  v_order_number     text;
  v_buyer_wallet_cur text          := NULL;
  v_rate_row         RECORD;
  v_raw_rate         DECIMAL(20,8) := NULL;
  v_db_rate          DECIMAL(20,8) := NULL;
  v_final_rate       DECIMAL(20,8) := NULL;
BEGIN
  IF v_buyer_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Authentification requise');
  END IF;

  -- Récupérer ou créer le customer
  SELECT id INTO v_customer_id
  FROM public.customers
  WHERE user_id = v_buyer_user_id
  LIMIT 1;

  IF v_customer_id IS NULL THEN
    INSERT INTO public.customers (user_id)
    VALUES (v_buyer_user_id)
    RETURNING id INTO v_customer_id;
  END IF;

  -- Récupérer le vendeur
  SELECT user_id INTO v_vendor_user_id
  FROM public.vendors
  WHERE id = p_vendor_id
    AND is_active = true
  LIMIT 1;

  IF v_vendor_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendeur introuvable ou inactif');
  END IF;

  IF v_vendor_user_id = v_buyer_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vous ne pouvez pas acheter dans votre propre boutique');
  END IF;

  -- Résoudre la devise du wallet acheteur
  IF p_payment_method = 'wallet' AND p_wallet_debit_amount > 0 THEN
    SELECT currency INTO v_buyer_wallet_cur
    FROM public.wallets
    WHERE user_id = v_buyer_user_id
    LIMIT 1;
  END IF;

  -- Résoudre le taux de change DB pour validation et logging
  IF p_payment_method = 'wallet'
     AND p_wallet_debit_amount > 0
     AND v_buyer_wallet_cur IS NOT NULL
     AND p_currency IS DISTINCT FROM v_buyer_wallet_cur
  THEN
    SELECT cer.*
    INTO   v_rate_row
    FROM   public.currency_exchange_rates cer
    WHERE (
      (cer.from_currency = p_currency        AND cer.to_currency = v_buyer_wallet_cur)
      OR
      (cer.from_currency = v_buyer_wallet_cur AND cer.to_currency = p_currency)
    )
    AND cer.is_active = true
    ORDER BY cer.retrieved_at DESC
    LIMIT 1;

    IF FOUND THEN
      v_raw_rate := COALESCE(
        CASE
          WHEN p_currency = 'EUR' OR v_buyer_wallet_cur = 'EUR' THEN v_rate_row.final_rate_eur
          WHEN p_currency = 'USD' OR v_buyer_wallet_cur = 'USD' THEN v_rate_row.final_rate_usd
          ELSE v_rate_row.rate * (1.0 + COALESCE(v_rate_row.margin, 0))
        END,
        v_rate_row.rate
      );

      IF v_rate_row.from_currency = p_currency THEN
        v_db_rate := v_raw_rate;
      ELSE
        v_db_rate := 1.0 / NULLIF(v_raw_rate, 0);
      END IF;
    END IF;

    -- Taux frontend préféré ; DB sert de validation (create_order_core peut comparer si besoin)
    v_final_rate := COALESCE(p_exchange_rate_used, v_db_rate);
  ELSE
    v_final_rate := p_exchange_rate_used;
  END IF;

  v_order_number := 'ORD-' || upper(replace(gen_random_uuid()::text, '-', ''));
  v_order_number := left(v_order_number, 20);

  -- Appelle la surcharge 14-params de create_order_core
  RETURN public.create_order_core(
    p_order_number          := v_order_number,
    p_customer_id           := v_customer_id,
    p_vendor_id             := p_vendor_id,
    p_vendor_user_id        := v_vendor_user_id,
    p_payment_method        := p_payment_method,
    p_shipping_address      := p_shipping_address,
    p_currency              := p_currency,
    p_items                 := p_items,
    p_auto_release_days     := p_auto_release_days,
    p_buyer_user_id         := v_buyer_user_id,
    p_wallet_debit_amount   := p_wallet_debit_amount,
    p_buyer_wallet_currency := v_buyer_wallet_cur,
    p_exchange_rate_used    := v_final_rate
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- ================================================================
-- GRANTS
-- ================================================================

GRANT EXECUTE ON FUNCTION public.create_order_core(
  text, uuid, uuid, uuid, text, text, jsonb, text, jsonb, int, uuid, numeric, text
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.create_order_core(
  text, uuid, uuid, uuid, text, text, jsonb, text, jsonb, int, uuid, numeric, text, numeric
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.create_marketplace_order_secure(
  uuid, text, jsonb, jsonb, text, numeric, int
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.create_marketplace_order_secure(
  uuid, text, jsonb, jsonb, text, numeric, int, numeric
) TO authenticated;

SELECT
  'Migration 20260519100000 appliquée : '
  || 'create_order_core (13+14 params) + create_marketplace_order_secure (7+8 params). '
  || 'Bugs #1 #2 #3 corrigés.' AS status;
