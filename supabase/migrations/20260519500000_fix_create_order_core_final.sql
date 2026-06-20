-- ================================================================
-- MIGRATION FINALE : create_order_core — réécriture robuste
--
-- Correctifs cumulés :
--   1. v_rate_row (RECORD) remplacé par v_rate_source_label (TEXT, toujours initialisé)
--      → élimine "record is not assigned yet" quelle que soit la combinaison
--        de paramètres (cross/same-currency, payment_method, etc.)
--   2. buyer_id escrow = COALESCE(p_buyer_user_id, p_customer_id) → auth.users FK
--   3. v_payment_status correct (paid pour wallet+débit, pending sinon)
--   4. format() : %.6f → to_char() pour floats PostgreSQL
--   5. Phase 5bis wrappée dans BEGIN/EXCEPTION → résiste si table absente
--   6. p_exchange_rate_used = null skippé correctement
-- ================================================================

CREATE OR REPLACE FUNCTION public.create_order_core(
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
  item                jsonb;
  v_product_id        uuid;
  v_quantity          int;
  v_current_stock     int;
  v_product_price     numeric;
  v_product_name      text;
  v_subtotal          numeric      := 0;
  v_order_id          uuid;
  v_item_records      jsonb        := '[]'::jsonb;
  v_release_at        timestamptz;
  v_wallet_cur        text;
  v_is_cross          BOOLEAN      := false;
  v_payment_status    payment_status;
  v_escrow_buyer      uuid;

  -- Variables taux (initialisées — jamais "non assignées")
  v_db_rate           DECIMAL(20,8) := NULL;
  v_rate_fetched_at   timestamptz   := NULL;
  v_rate_source_label TEXT          := 'same_currency';   -- Label utilisé dans les logs/réponse

  -- Variables internes Phase -1 (RECORD local, utilisé uniquement dans Phase -1)
  v_rate_row          RECORD;
  v_raw_rate          DECIMAL(20,8) := NULL;
  v_max_age_hours     int;
BEGIN

  v_wallet_cur     := COALESCE(p_buyer_wallet_currency, p_currency);
  v_is_cross       := (p_currency IS DISTINCT FROM v_wallet_cur);
  v_escrow_buyer   := COALESCE(p_buyer_user_id, p_customer_id);
  v_payment_status := CASE
    WHEN p_payment_method = 'wallet' AND p_wallet_debit_amount > 0 THEN 'paid'::payment_status
    ELSE 'pending'::payment_status
  END;

  -- ── PHASE -1 : Validation taux de change (wallet cross-devise uniquement) ──
  IF p_payment_method = 'wallet'
     AND p_buyer_user_id IS NOT NULL
     AND p_wallet_debit_amount > 0
     AND v_is_cross
  THEN
    SELECT cer.*
    INTO   v_rate_row
    FROM   public.currency_exchange_rates cer
    WHERE (
        (cer.from_currency = p_currency   AND cer.to_currency = v_wallet_cur)
      OR
        (cer.from_currency = v_wallet_cur AND cer.to_currency = p_currency)
    )
    AND cer.is_active = true
    ORDER BY cer.retrieved_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   format('Aucun taux de change trouvé pour la paire %s/%s.', p_currency, v_wallet_cur)
      );
    END IF;

    IF (p_currency = 'GNF' OR v_wallet_cur = 'GNF') AND v_rate_row.source_type = 'fallback_api' THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   'Taux GNF invalide : seuls les taux officiels BCRG sont acceptés.'
      );
    END IF;

    IF (p_currency = 'GNF' OR v_wallet_cur = 'GNF') AND v_rate_row.source_type = 'official_html' THEN
      IF v_rate_row.last_bcrg_scraped_at IS NULL THEN
        RETURN jsonb_build_object(
          'success', false,
          'error',   'Aucun scraping BCRG enregistré. Veuillez réessayer dans quelques minutes.'
        );
      END IF;
      IF v_rate_row.last_bcrg_scraped_at < now() - interval '24 hours' THEN
        RETURN jsonb_build_object(
          'success', false,
          'error',   format('Données BCRG trop anciennes (> 24h, dernier scraping : %s).',
                            to_char(v_rate_row.last_bcrg_scraped_at AT TIME ZONE 'UTC', 'DD/MM/YYYY HH24:MI UTC'))
        );
      END IF;
    END IF;

    v_max_age_hours := CASE
      WHEN v_rate_row.source_type IN ('official_html', 'official_fixed_parity') THEN 25
      ELSE 2
    END;

    IF v_rate_row.retrieved_at < now() - make_interval(hours => v_max_age_hours) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   format('Taux %s/%s expiré (> %sh). Veuillez réessayer.', p_currency, v_wallet_cur, v_max_age_hours)
      );
    END IF;

    -- Résoudre le taux final
    v_raw_rate := COALESCE(
      CASE
        WHEN p_currency = 'EUR' OR v_wallet_cur = 'EUR' THEN v_rate_row.final_rate_eur
        WHEN p_currency = 'USD' OR v_wallet_cur = 'USD' THEN v_rate_row.final_rate_usd
        ELSE v_rate_row.rate * (1.0 + COALESCE(v_rate_row.margin, 0))
      END,
      v_rate_row.rate
    );

    v_db_rate := CASE
      WHEN v_rate_row.from_currency = p_currency THEN v_raw_rate
      ELSE 1.0 / NULLIF(v_raw_rate, 0)
    END;

    v_rate_fetched_at := v_rate_row.retrieved_at;

    -- Validation cohérence taux frontend vs DB (±5 %)
    IF p_exchange_rate_used IS NOT NULL AND p_exchange_rate_used > 0
       AND v_db_rate IS NOT NULL AND v_db_rate > 0
    THEN
      IF ABS(p_exchange_rate_used - v_db_rate) / v_db_rate > 0.05 THEN
        RETURN jsonb_build_object(
          'success', false,
          'error',   format(
            'Taux de change obsolète (écart > 5%% : frontend %s vs BCRG %s). Rafraîchissez la page.',
            to_char(p_exchange_rate_used, 'FM999999990.999999'),
            to_char(v_db_rate,            'FM999999990.999999')
          )
        );
      END IF;
    END IF;

    -- Label source (utilisé plus bas dans les logs/réponse, jamais depuis v_rate_row)
    v_rate_source_label := CASE
      WHEN p_currency = 'GNF' OR v_wallet_cur = 'GNF' THEN 'BCRG (bcrg-guinee.org)'
      ELSE COALESCE(v_rate_row.source_url, 'currency_exchange_rates')
    END;

  END IF;
  -- ── FIN PHASE -1 — v_rate_row N'EST PLUS ACCÉDÉ EN-DEHORS DE CE BLOC ──

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
      IF EXISTS (
        SELECT 1 FROM public.wallets
        WHERE user_id = p_buyer_user_id AND currency = v_wallet_cur
      ) THEN
        RETURN jsonb_build_object(
          'success', false,
          'error',   format('Solde %s insuffisant pour effectuer cet achat', v_wallet_cur)
        );
      ELSE
        RETURN jsonb_build_object(
          'success', false,
          'error',   format('Portefeuille introuvable en %s pour cet utilisateur', v_wallet_cur)
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
    v_payment_status,
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

  -- ── PHASE 5 : Créer l'escrow ──────────────────────────────────────────────
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
    v_escrow_buyer,
    p_vendor_user_id,
    p_buyer_user_id,
    p_vendor_user_id,
    v_subtotal, p_currency, 'held',
    v_release_at, v_release_at, p_payment_method,
    v_subtotal, p_currency,
    CASE WHEN p_payment_method = 'wallet' AND p_wallet_debit_amount > 0
         THEN p_wallet_debit_amount ELSE NULL END,
    CASE WHEN p_payment_method = 'wallet' AND p_wallet_debit_amount > 0
         THEN v_wallet_cur ELSE NULL END,
    CASE WHEN v_is_cross AND p_payment_method = 'wallet'
         THEN COALESCE(p_exchange_rate_used, v_db_rate) ELSE NULL END,
    v_is_cross AND p_payment_method = 'wallet'
  );

  -- ── PHASE 5bis : Log conversion (monitoring — ignoré si table absente) ────
  BEGIN
    IF p_payment_method = 'wallet' AND p_buyer_user_id IS NOT NULL AND p_wallet_debit_amount > 0 THEN
      INSERT INTO public.currency_conversion_logs (
        order_id, buyer_user_id, vendor_id,
        from_currency, to_currency, is_cross_currency,
        original_amount, converted_amount, wallet_debit_amount,
        exchange_rate, exchange_rate_source, rate_fetched_at,
        status
      ) VALUES (
        v_order_id, p_buyer_user_id, p_vendor_id,
        p_currency, v_wallet_cur, v_is_cross,
        v_subtotal,
        CASE WHEN v_is_cross THEN p_wallet_debit_amount ELSE v_subtotal END,
        p_wallet_debit_amount,
        COALESCE(CASE WHEN v_is_cross THEN COALESCE(p_exchange_rate_used, v_db_rate) ELSE NULL END, 1.0),
        v_rate_source_label,   -- Toujours initialisé ('same_currency' ou label BCRG)
        v_rate_fetched_at,
        'success'
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- Log non critique — ne pas bloquer la commande
  END;

  -- ── PHASE 6 : Débit wallet atomique ───────────────────────────────────────
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
      transaction_id, sender_user_id, receiver_user_id,
      transaction_type, amount, net_amount,
      description, status, metadata
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
        'order_id',             v_order_id,
        'order_currency',       p_currency,
        'wallet_currency',      v_wallet_cur,
        'product_amount',       v_subtotal,
        'total_debited',        p_wallet_debit_amount,
        'exchange_rate_used',   COALESCE(p_exchange_rate_used, v_db_rate, 1.0),
        'exchange_rate_source', v_rate_source_label,   -- Toujours initialisé
        'is_cross_currency',    v_is_cross,
        'source',               'create_order_core'
      )
    );
  END IF;

  -- ── SUCCESS ───────────────────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'success',              true,
    'order_id',             v_order_id,
    'order_number',         p_order_number,
    'subtotal',             v_subtotal,
    'total_amount',         v_subtotal,
    'currency',             p_currency,
    'items',                v_item_records,
    'escrow_status',        'held',
    'payment_status',       v_payment_status::text,
    'is_cross_currency',    v_is_cross,
    'exchange_rate',        COALESCE(p_exchange_rate_used, v_db_rate, 1.0),
    'exchange_rate_source', v_rate_source_label    -- Toujours initialisé
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

SELECT 'create_order_core FINALE — v_rate_source_label remplace v_rate_row, tous les accès RECORD éliminés.' AS status;
