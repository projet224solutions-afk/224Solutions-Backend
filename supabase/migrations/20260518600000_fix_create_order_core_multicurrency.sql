-- ================================================================
-- FIX create_order_core — validation taux de change + logging
--
-- Bugs corrigés :
--   1. Aucune vérification du taux de change côté backend avant débit
--      wallet — le frontend pouvait envoyer un montant incorrect ou
--      un taux obsolète sans que le backend s'en aperçoive.
--
--   2. La table currency_conversion_logs n'était jamais alimentée par
--      le backend → monitoring PDG impossible.
--
--   3. Les colonnes multi-devises d'escrow_transactions n'étaient pas
--      renseignées (original_amount, buyer_debit_amount, etc.)
--
-- Nouveau paramètre :
--   p_exchange_rate_used NUMERIC DEFAULT NULL
--   Taux de conversion utilisé (passé par create_marketplace_order_secure
--   après validation côté backend depuis currency_exchange_rates)
--
-- Nouvelles phases :
--   Phase -1 : si paiement wallet cross-devise, vérifier qu'un taux
--              actif < 2h existe dans currency_exchange_rates.
--              Si absent → rejeter la commande.
--   Phase 5bis : INSERT dans currency_conversion_logs pour audit PDG.
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
  p_order_number           text,
  p_customer_id            uuid,
  p_vendor_id              uuid,
  p_vendor_user_id         uuid,
  p_payment_method         text,
  p_payment_intent_id      text     DEFAULT NULL,
  p_shipping_address       jsonb    DEFAULT '{}'::jsonb,
  p_currency               text     DEFAULT 'GNF',
  p_items                  jsonb    DEFAULT '[]'::jsonb,
  p_auto_release_days      int      DEFAULT 7,
  p_buyer_user_id          uuid     DEFAULT NULL,
  p_wallet_debit_amount    numeric  DEFAULT 0,
  p_buyer_wallet_currency  text     DEFAULT NULL,
  p_exchange_rate_used     numeric  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item              jsonb;
  v_product_id      uuid;
  v_quantity        int;
  v_current_stock   int;
  v_product_price   numeric;
  v_product_name    text;
  v_subtotal        numeric      := 0;
  v_order_id        uuid;
  v_item_records    jsonb        := '[]'::jsonb;
  v_release_at      timestamptz;
  v_wallet_cur      text;
  v_rate_row        RECORD;
  v_raw_rate        DECIMAL(20,8) := NULL;
  v_db_rate         DECIMAL(20,8) := NULL;
  v_rate_fetched_at timestamptz  := NULL;
  v_is_cross        BOOLEAN      := false;
BEGIN

  -- Résoudre la devise du wallet : paramètre fourni OU devise de commande par défaut
  v_wallet_cur  := COALESCE(p_buyer_wallet_currency, p_currency);
  v_is_cross    := (p_currency IS DISTINCT FROM v_wallet_cur);

  -- ── PHASE -1 : Vérifier la fraîcheur du taux de change ────────────────────
  -- Obligatoire pour les paiements wallet cross-devise.
  -- Empêche un débit basé sur un taux obsolète ou inexistant.
  IF p_payment_method = 'wallet'
     AND p_buyer_user_id IS NOT NULL
     AND p_wallet_debit_amount > 0
     AND v_is_cross
  THEN
    SELECT cer.*
    INTO   v_rate_row
    FROM   public.currency_exchange_rates cer
    WHERE (
      (cer.from_currency = p_currency    AND cer.to_currency = v_wallet_cur)
      OR
      (cer.from_currency = v_wallet_cur  AND cer.to_currency = p_currency)
    )
    AND cer.is_active = true
    AND cer.retrieved_at > now() - interval '2 hours'
    ORDER BY cer.retrieved_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   format(
          'Taux de change %s/%s introuvable ou expiré (> 2h). Veuillez rafraîchir la page et réessayer.',
          p_currency, v_wallet_cur
        )
      );
    END IF;

    v_rate_fetched_at := v_rate_row.retrieved_at;

    -- Résoudre le taux final (marge incluse)
    v_raw_rate := COALESCE(
      CASE
        WHEN p_currency = 'EUR' OR v_wallet_cur = 'EUR' THEN v_rate_row.final_rate_eur
        WHEN p_currency = 'USD' OR v_wallet_cur = 'USD' THEN v_rate_row.final_rate_usd
        ELSE v_rate_row.rate * (1.0 + COALESCE(v_rate_row.margin, 0))
      END,
      v_rate_row.rate
    );

    -- Convertir en taux directionnel (vendeur → acheteur)
    IF v_rate_row.from_currency = p_currency THEN
      v_db_rate := v_raw_rate;
    ELSE
      v_db_rate := 1.0 / NULLIF(v_raw_rate, 0);
    END IF;

    -- Si le frontend n'a pas fourni de taux, on prend le taux DB
    IF p_exchange_rate_used IS NULL OR p_exchange_rate_used <= 0 THEN
      -- OK : utiliser le taux DB comme référence de log
      NULL;
    ELSE
      -- Vérifier la cohérence : écart max 5 %
      IF v_db_rate IS NOT NULL AND v_db_rate > 0 THEN
        IF ABS(p_exchange_rate_used - v_db_rate) / v_db_rate > 0.05 THEN
          RETURN jsonb_build_object(
            'success', false,
            'error',   format(
              'Taux de change obsolète (écart > 5%% : frontend %.8f vs DB %.8f). Veuillez rafraîchir la page.',
              p_exchange_rate_used, v_db_rate
            )
          );
        END IF;
      END IF;
    END IF;
  END IF;

  -- ── PHASE 0 : Vérification solde wallet ──────────────────────────────────
  -- p_wallet_debit_amount est DÉJÀ en v_wallet_cur (converti par le frontend)
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

  -- ── PHASE 1 : Valider les produits ────────────────────────────────────────
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

  -- ── PHASE 2 : Créer la commande ───────────────────────────────────────────
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

  -- ── PHASE 3 : Lignes de commande ──────────────────────────────────────────
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

  -- ── PHASE 4 : Décrémenter le stock ────────────────────────────────────────
  UPDATE products p
  SET    stock_quantity = GREATEST(0, COALESCE(p.stock_quantity, 0) - (r->>'quantity')::int),
         updated_at     = now()
  FROM   jsonb_array_elements(v_item_records) AS r
  WHERE  p.id = (r->>'product_id')::uuid;

  -- ── PHASE 5 : Créer l'escrow (avec colonnes multi-devises) ────────────────
  v_release_at := now() + (p_auto_release_days || ' days')::interval;

  INSERT INTO escrow_transactions (
    order_id, buyer_id, seller_id, payer_id, receiver_id,
    amount, currency, status,
    auto_release_at, auto_release_date, payment_method,
    original_amount, original_currency,
    buyer_debit_amount, buyer_debit_currency,
    exchange_rate_used, is_cross_currency
  ) VALUES (
    v_order_id,
    p_customer_id,
    p_vendor_user_id,
    p_buyer_user_id,
    p_vendor_user_id,
    v_subtotal, p_currency, 'held',
    v_release_at, v_release_at,
    p_payment_method,
    v_subtotal,
    p_currency,
    CASE WHEN p_payment_method = 'wallet' AND p_wallet_debit_amount > 0
         THEN p_wallet_debit_amount ELSE NULL END,
    CASE WHEN p_payment_method = 'wallet' AND p_wallet_debit_amount > 0
         THEN v_wallet_cur ELSE NULL END,
    CASE WHEN v_is_cross AND p_payment_method = 'wallet'
         THEN COALESCE(p_exchange_rate_used, v_db_rate) ELSE NULL END,
    v_is_cross AND p_payment_method = 'wallet'
  );

  -- ── PHASE 5bis : Log de conversion (monitoring PDG) ───────────────────────
  IF p_payment_method = 'wallet' AND p_buyer_user_id IS NOT NULL AND p_wallet_debit_amount > 0 THEN
    INSERT INTO public.currency_conversion_logs (
      order_id,
      buyer_user_id,
      vendor_id,
      from_currency,
      to_currency,
      is_cross_currency,
      original_amount,
      converted_amount,
      wallet_debit_amount,
      exchange_rate,
      exchange_rate_source,
      rate_fetched_at,
      status
    ) VALUES (
      v_order_id,
      p_buyer_user_id,
      p_vendor_id,
      p_currency,
      v_wallet_cur,
      v_is_cross,
      v_subtotal,
      CASE WHEN v_is_cross THEN p_wallet_debit_amount ELSE v_subtotal END,
      p_wallet_debit_amount,
      CASE WHEN v_is_cross THEN COALESCE(p_exchange_rate_used, v_db_rate) ELSE 1.0 END,
      CASE WHEN v_is_cross THEN 'create_order_core (currency_exchange_rates)' ELSE 'same_currency' END,
      v_rate_fetched_at,
      'success'
    );
  END IF;

  -- ── PHASE 6 : Débit wallet atomique ───────────────────────────────────────
  -- v_wallet_cur = devise du wallet acheteur (GNF, XOF, EUR…)
  -- p_wallet_debit_amount = montant DÉJÀ converti en v_wallet_cur par le frontend
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
        'exchange_rate_used',  COALESCE(p_exchange_rate_used, v_db_rate),
        'is_cross_currency',   v_is_cross,
        'source',              'create_order_core'
      )
    );
  END IF;

  -- ── SUCCESS ───────────────────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'success',           true,
    'order_id',          v_order_id,
    'order_number',      p_order_number,
    'subtotal',          v_subtotal,
    'total_amount',      v_subtotal,
    'currency',          p_currency,
    'items',             v_item_records,
    'escrow_status',     'held',
    'is_cross_currency', v_is_cross,
    'exchange_rate',     COALESCE(p_exchange_rate_used, v_db_rate, 1.0)
  );

EXCEPTION WHEN OTHERS THEN
  -- Tenter de logger l'erreur de conversion si applicable
  BEGIN
    IF p_payment_method = 'wallet' AND p_buyer_user_id IS NOT NULL
       AND p_wallet_debit_amount > 0 AND v_is_cross
    THEN
      INSERT INTO public.currency_conversion_logs (
        buyer_user_id, vendor_id, from_currency, to_currency,
        is_cross_currency, original_amount, wallet_debit_amount,
        status, error_message
      ) VALUES (
        p_buyer_user_id, p_vendor_id, p_currency, v_wallet_cur,
        true, v_subtotal, p_wallet_debit_amount,
        'error', SQLERRM
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL; -- Ne pas masquer l'erreur principale
  END;

  RETURN jsonb_build_object(
    'success', false,
    'error',   SQLERRM
  );
END;
$$;

SELECT 'create_order_core — validation taux de change + logging multi-devises opérationnel.' AS status;
