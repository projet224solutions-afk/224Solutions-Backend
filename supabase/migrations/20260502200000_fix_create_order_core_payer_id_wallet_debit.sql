-- ============================================================
-- FIX 1 : payer_id NULL dans escrow_transactions
-- FIX 2 : débit wallet absent pour paiement_method = 'wallet'
-- ============================================================
-- PROBLÈME 1 : create_order_core insère buyer_id (= customers.id) mais
-- jamais payer_id (= auth.users.id). Or cancel_order_and_refund_wallet
-- teste "v_escrow.payer_id IS NOT NULL" → remboursement jamais effectué.
--
-- PROBLÈME 2 : Pour les paiements wallet, le solde du client n'est
-- jamais débité. La commande est marquée payée mais l'argent reste
-- dans le wallet. La balance est vérifiée côté frontend mais sans débit.
--
-- FIX : Deux nouveaux paramètres DEFAULT NULL / 0 → backward-compatible.
--   p_buyer_user_id  → auth.users.id de l'acheteur → rempli dans payer_id
--   p_wallet_debit_amount → montant total (produits + commission) à débiter
--                           du wallet si payment_method = 'wallet'
-- ============================================================

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
  -- NOUVEAUX paramètres (DEFAULT = backward-compatible)
  p_buyer_user_id          uuid    DEFAULT NULL,   -- auth.users.id de l'acheteur
  p_wallet_debit_amount    numeric DEFAULT 0       -- montant à débiter du wallet (0 = pas de débit)
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item            jsonb;
  product_id      uuid;
  quantity        int;
  current_stock   int;
  product_price   numeric;
  product_name    text;
  subtotal        numeric := 0;
  order_id        uuid;
  item_records    jsonb   := '[]'::jsonb;
  v_buyer_wallet_id bigint;
BEGIN

  -- ====== PHASE 0 : Vérification solde wallet (si paiement wallet) ======
  -- Vérifié en amont du FOR LOCK pour fail-fast avant toute modification.
  IF p_payment_method = 'wallet'
     AND p_buyer_user_id IS NOT NULL
     AND p_wallet_debit_amount > 0
  THEN
    PERFORM 1
    FROM public.wallets
    WHERE user_id = p_buyer_user_id
      AND balance >= p_wallet_debit_amount
    FOR UPDATE;                        -- lock la ligne pour éviter la race condition

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   'Solde wallet insuffisant pour effectuer cet achat'
      );
    END IF;
  END IF;

  -- ====== PHASE 1 : Validate all products + lock rows ======
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    product_id := (item->>'product_id')::uuid;
    quantity   := (item->>'quantity')::int;

    SELECT p.stock_quantity, p.price, p.name
    INTO   current_stock, product_price, product_name
    FROM   products p
    WHERE  p.id        = product_id
      AND  p.vendor_id = p_vendor_id
      AND  p.is_active = true
    FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   format('Produit %s introuvable, inactif ou mauvais vendeur', product_id)
      );
    END IF;

    IF current_stock IS NOT NULL AND current_stock < quantity THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   format('Stock insuffisant pour "%s" : %s disponible, %s demandé', product_name, current_stock, quantity)
      );
    END IF;

    item_records := item_records || jsonb_build_object(
      'product_id',   product_id,
      'product_name', product_name,
      'quantity',     quantity,
      'unit_price',   product_price,
      'total_price',  product_price * quantity,
      'variant_id',   item->>'variant_id'
    );

    subtotal := subtotal + (product_price * quantity);
  END LOOP;

  -- ====== PHASE 2 : Create order ======
  INSERT INTO orders (
    order_number, customer_id, vendor_id, status,
    payment_status, payment_method, payment_intent_id,
    subtotal, total_amount, shipping_address, currency
  ) VALUES (
    p_order_number, p_customer_id, p_vendor_id, 'pending',
    CASE WHEN p_payment_method IN ('cash', 'cod') THEN 'pending' ELSE 'processing' END,
    p_payment_method, p_payment_intent_id,
    subtotal, subtotal, p_shipping_address, p_currency
  )
  RETURNING id INTO order_id;

  -- ====== PHASE 3 : Insert order items ======
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

  -- ====== PHASE 4 : Decrement stock (all at once) ======
  UPDATE products p
  SET    stock_quantity = GREATEST(0, COALESCE(p.stock_quantity, 0) - (r->>'quantity')::int),
         updated_at     = now()
  FROM   jsonb_array_elements(item_records) AS r
  WHERE  p.id = (r->>'product_id')::uuid;

  -- ====== PHASE 5 : Create escrow (avec payer_id et receiver_id) ======
  INSERT INTO escrow_transactions (
    order_id, buyer_id, seller_id, payer_id, receiver_id,
    amount, currency, status, auto_release_at, payment_method
  ) VALUES (
    order_id,
    p_customer_id,          -- customers.id
    p_vendor_user_id,       -- auth.users.id du vendeur
    p_buyer_user_id,        -- auth.users.id de l'acheteur (FIX payer_id)
    p_vendor_user_id,       -- auth.users.id du vendeur   (FIX receiver_id)
    subtotal,
    p_currency,
    'held',
    now() + (p_auto_release_days || ' days')::interval,
    p_payment_method
  );

  -- ====== PHASE 6 : Débit wallet atomique (si paiement wallet) ======
  IF p_payment_method = 'wallet'
     AND p_buyer_user_id IS NOT NULL
     AND p_wallet_debit_amount > 0
  THEN
    -- Débit atomique (le FOR UPDATE de la phase 0 garantit qu'aucune autre
    -- transaction n'a modifié le solde entre la vérification et le débit)
    UPDATE public.wallets
    SET    balance    = balance - p_wallet_debit_amount,
           updated_at = now()
    WHERE  user_id = p_buyer_user_id;

    -- Log wallet_transactions
    SELECT id INTO v_buyer_wallet_id
    FROM   public.wallets
    WHERE  user_id = p_buyer_user_id;

    IF v_buyer_wallet_id IS NOT NULL THEN
      INSERT INTO public.wallet_transactions (
        sender_wallet_id,
        receiver_wallet_id,
        transaction_type,
        amount,
        description,
        status,
        metadata
      ) VALUES (
        v_buyer_wallet_id,
        v_buyer_wallet_id,
        'marketplace_purchase',
        p_wallet_debit_amount,
        'Paiement commande marketplace — Fonds bloqués en Escrow',
        'completed',
        jsonb_build_object(
          'order_id',       order_id,
          'currency',       p_currency,
          'product_amount', subtotal,
          'total_debited',  p_wallet_debit_amount,
          'source',         'create_order_core'
        )
      );
    END IF;
  END IF;

  -- ====== SUCCESS ======
  RETURN jsonb_build_object(
    'success',      true,
    'order_id',     order_id,
    'order_number', p_order_number,
    'subtotal',     subtotal,
    'total_amount', subtotal,
    'currency',     p_currency,
    'items',        item_records,
    'escrow_status','held'
  );

EXCEPTION WHEN OTHERS THEN
  -- La transaction PostgreSQL est automatiquement annulée (rollback)
  RETURN jsonb_build_object(
    'success', false,
    'error',   SQLERRM
  );
END;
$$;

COMMENT ON FUNCTION public.create_order_core IS
  'Création atomique commande + items + décrément stock + escrow (avec payer_id, receiver_id) + débit wallet optionnel. Tous en une seule transaction PostgreSQL.';

-- Pas de changement de GRANT nécessaire (SECURITY DEFINER, pas de revoke/grant supplémentaire requis)
