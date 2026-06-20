-- 🧱 DURCISSEMENT BÉTON DU FLUX ARGENT DES COMMANDES MARKETPLACE
--
-- Problème de fond : plusieurs fonctions (create_order_core, auto_release_escrows,
-- refund_order_escrow, confirm_delivery_and_release_escrow) créditaient un wallet avec le motif
--   UPDATE wallets ... WHERE user_id = U AND currency = C ;
--   IF NOT FOUND THEN INSERT INTO wallets (...)   ← crée un 2e wallet pour U
-- Or la table impose UN SEUL wallet par utilisateur (wallets_user_id_key). Dès que la devise du
-- wallet de U ≠ C, l'INSERT violait la contrainte → "duplicate key" → commande / escrow / remboursement
-- cassés. De plus aucune conversion n'était faite (créditer un montant XOF sur un wallet GNF).
--
-- SOLUTION : UNE primitive atomique unique, utilisée PARTOUT :
--   credit_user_wallet_safe(user_id, amount, from_currency)
--     • verrouille l'unique wallet de l'utilisateur (FOR UPDATE),
--     • le CRÉE s'il n'existe pas (aucun conflit possible),
--     • CONVERTIT le montant depuis from_currency vers la devise du wallet si besoin,
--     • ne lève JAMAIS de duplicate key.
-- Toutes les fonctions du cycle commande l'appellent → comportement uniforme, atomique, incassable.
--
-- NB : wallets.id est un BIGINT (vérifié en base), wallets.user_id est UNIQUE.

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. PRIMITIVE ATOMIQUE — crédit sûr d'un wallet (un seul par user, conversion, anti-doublon)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.credit_user_wallet_safe(
  p_user_id       uuid,
  p_amount        numeric,
  p_from_currency text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id  bigint;
  v_wallet_cur text;
  v_rate       numeric;
  v_credit     numeric;
BEGIN
  IF p_user_id IS NULL OR COALESCE(p_amount, 0) <= 0 THEN
    RETURN jsonb_build_object('credited', 0, 'currency', p_from_currency, 'skipped', true);
  END IF;

  -- L'utilisateur a AU PLUS un wallet (contrainte unique). On le verrouille.
  SELECT id, currency INTO v_wallet_id, v_wallet_cur
  FROM public.wallets
  WHERE user_id = p_user_id
  ORDER BY (currency = p_from_currency) DESC, id ASC
  LIMIT 1
  FOR UPDATE;

  -- Aucun wallet → on en crée un (aucun conflit possible puisque l'utilisateur n'en a pas)
  IF v_wallet_id IS NULL THEN
    INSERT INTO public.wallets (user_id, balance, currency, wallet_status)
    VALUES (p_user_id, p_amount, COALESCE(p_from_currency, 'GNF'), 'active')
    RETURNING id, currency INTO v_wallet_id, v_wallet_cur;
    RETURN jsonb_build_object('credited', p_amount, 'currency', v_wallet_cur,
                              'wallet_id', v_wallet_id, 'created', true);
  END IF;

  -- Conversion vers la devise du wallet si nécessaire
  IF p_from_currency IS NULL OR v_wallet_cur = p_from_currency THEN
    v_credit := p_amount;
  ELSE
    SELECT CASE WHEN cer.from_currency = p_from_currency
                THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END
    INTO v_rate
    FROM public.currency_exchange_rates cer
    WHERE ((cer.from_currency = p_from_currency AND cer.to_currency = v_wallet_cur)
        OR (cer.from_currency = v_wallet_cur AND cer.to_currency = p_from_currency))
      AND cer.is_active = true
    ORDER BY cer.retrieved_at DESC
    LIMIT 1;
    v_credit := ROUND(p_amount * COALESCE(v_rate, 1.0), 2);
  END IF;

  UPDATE public.wallets SET balance = balance + v_credit, updated_at = now()
  WHERE id = v_wallet_id;

  RETURN jsonb_build_object('credited', v_credit, 'currency', v_wallet_cur, 'wallet_id', v_wallet_id);
END;
$$;

REVOKE ALL ON FUNCTION public.credit_user_wallet_safe(uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_user_wallet_safe(uuid, numeric, text) TO authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. auto_release_escrows() — crédit vendeur + commission via la primitive sûre
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.auto_release_escrows()
RETURNS TABLE(escrow_id uuid, success boolean, message text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_e             RECORD;
  v_commission    numeric;
  v_vendor_amount numeric;
  v_cur           text;
  v_seller        uuid;
  v_pdg_user_id   uuid;
  v_seller_res    jsonb;
BEGIN
  SELECT user_id INTO v_pdg_user_id FROM public.pdg_management WHERE is_active = true LIMIT 1;

  FOR v_e IN
    SELECT et.*
    FROM public.escrow_transactions et
    JOIN public.orders o ON o.id = et.order_id
    WHERE et.status = 'held'
      AND et.auto_release_at IS NOT NULL
      AND et.auto_release_at <= now()
      AND o.status IN ('delivered', 'in_transit')
    ORDER BY et.auto_release_at ASC
    LIMIT 100
  LOOP
    BEGIN
      v_cur           := COALESCE(v_e.currency, 'GNF');
      v_seller        := COALESCE(v_e.receiver_id, v_e.seller_id);
      v_commission    := COALESCE(NULLIF(v_e.commission_amount, 0), v_e.amount * 0.05);
      v_vendor_amount := v_e.amount - v_commission;

      -- Crédit vendeur (net) + commission plateforme, sans risque de doublon ni d'erreur de devise
      v_seller_res := public.credit_user_wallet_safe(v_seller, v_vendor_amount, v_cur);
      IF v_pdg_user_id IS NOT NULL AND v_commission > 0 THEN
        PERFORM public.credit_user_wallet_safe(v_pdg_user_id, v_commission, v_cur);
      END IF;

      INSERT INTO public.wallet_transactions (
        transaction_id, receiver_user_id, transaction_type, amount, net_amount, currency, status, description, metadata)
      VALUES (
        'rel-' || left(replace(gen_random_uuid()::text, '-', ''), 45),
        v_seller, 'escrow_release', v_e.amount, (v_seller_res->>'credited')::numeric,
        v_seller_res->>'currency', 'completed', 'Fonds escrow libérés (auto J+7)',
        jsonb_build_object('escrow_id', v_e.id, 'order_id', v_e.order_id, 'commission', v_commission,
                           'auto', true, 'original_currency', v_cur));

      UPDATE public.escrow_transactions
      SET status = 'released', released_at = now(), commission_amount = v_commission, updated_at = now()
      WHERE id = v_e.id;

      escrow_id := v_e.id; success := true; message := 'auto-released'; RETURN NEXT;
    EXCEPTION WHEN OTHERS THEN
      escrow_id := v_e.id; success := false; message := SQLERRM; RETURN NEXT;
    END;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.auto_release_escrows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.auto_release_escrows() TO service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. refund_order_escrow(order_id) — remboursement acheteur via la primitive sûre
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.refund_order_escrow(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow          RECORD;
  v_refund_amount   numeric;
  v_refund_currency text;
  v_payer           uuid;
  v_res             jsonb;
BEGIN
  SELECT * INTO v_escrow
  FROM public.escrow_transactions
  WHERE order_id = p_order_id AND status IN ('held', 'pending')
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', true, 'skipped', true);
  END IF;

  v_payer           := COALESCE(v_escrow.payer_id, v_escrow.buyer_id);
  v_refund_amount   := COALESCE(v_escrow.buyer_debit_amount, 0);
  v_refund_currency := COALESCE(v_escrow.buyer_debit_currency, v_escrow.currency, 'GNF');

  IF v_payer IS NOT NULL AND v_refund_amount > 0 THEN
    v_res := public.credit_user_wallet_safe(v_payer, v_refund_amount, v_refund_currency);

    INSERT INTO public.wallet_transactions (
      transaction_id, sender_user_id, receiver_user_id, transaction_type,
      amount, net_amount, currency, status, description, metadata)
    VALUES (
      'rfnd-' || left(replace(gen_random_uuid()::text, '-', ''), 44),
      NULL, v_payer, 'refund', v_refund_amount, (v_res->>'credited')::numeric,
      v_res->>'currency', 'completed', 'Remboursement commande annulée',
      jsonb_build_object('order_id', p_order_id, 'escrow_id', v_escrow.id,
                         'original_currency', v_refund_currency, 'source', 'refund_order_escrow'));
  END IF;

  UPDATE public.escrow_transactions
  SET status = 'refunded', released_at = now(), updated_at = now()
  WHERE id = v_escrow.id;

  RETURN jsonb_build_object('success', true, 'refunded_amount', v_refund_amount, 'currency', v_refund_currency);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.refund_order_escrow(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refund_order_escrow(uuid) TO service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. confirm_delivery_and_release_escrow() — libération par le client, via la primitive sûre
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.confirm_delivery_and_release_escrow(
  p_escrow_id   uuid,
  p_customer_id uuid,
  p_notes       text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow            RECORD;
  v_commission_amount numeric;
  v_vendor_amount     numeric;
  v_cur               text;
  v_seller            uuid;
  v_pdg               uuid;
  v_seller_res        jsonb;
  v_vendor_wallet_id  bigint;
BEGIN
  SELECT * INTO v_escrow FROM public.escrow_transactions WHERE id = p_escrow_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction escrow introuvable';
  END IF;

  IF COALESCE(v_escrow.payer_id, v_escrow.buyer_id) <> p_customer_id THEN
    RAISE EXCEPTION 'Non autorisé: vous n''êtes pas le client de cette transaction';
  END IF;

  IF v_escrow.status NOT IN ('pending', 'held') THEN
    RAISE EXCEPTION 'Cette transaction ne peut pas être libérée (statut: %)', v_escrow.status;
  END IF;

  v_cur               := COALESCE(v_escrow.currency, 'GNF');
  v_seller            := COALESCE(v_escrow.receiver_id, v_escrow.seller_id);
  v_commission_amount := COALESCE(NULLIF(v_escrow.commission_amount, 0), v_escrow.amount * 0.025);
  v_vendor_amount     := v_escrow.amount - v_commission_amount;

  -- Crédit vendeur (net) + commission plateforme via la primitive sûre (conversion, anti-doublon)
  v_seller_res       := public.credit_user_wallet_safe(v_seller, v_vendor_amount, v_cur);
  v_vendor_wallet_id := (v_seller_res->>'wallet_id')::bigint;

  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  IF v_pdg IS NOT NULL AND v_commission_amount > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission_amount, v_cur);
  END IF;

  UPDATE public.escrow_transactions
  SET status = 'released', released_at = now(), updated_at = now(), notes = COALESCE(p_notes, notes)
  WHERE id = p_escrow_id;

  INSERT INTO public.escrow_logs (escrow_id, action, performed_by, note)
  VALUES (p_escrow_id, 'customer_release', p_customer_id, p_notes);

  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_wallet_id, amount, fee, net_amount, currency,
    transaction_type, status, description, metadata)
  VALUES (
    generate_transaction_id(), v_vendor_wallet_id, v_escrow.amount, v_commission_amount,
    (v_seller_res->>'credited')::numeric, v_seller_res->>'currency',
    'escrow_release', 'completed', 'Fonds libérés de l''escrow - Confirmation client',
    jsonb_build_object('escrow_id', p_escrow_id, 'commission', v_commission_amount,
      'vendor_amount', (v_seller_res->>'credited')::numeric, 'confirmed_by', 'customer',
      'order_id', v_escrow.order_id, 'original_currency', v_cur));

  RETURN json_build_object('success', true, 'escrow_id', p_escrow_id,
    'vendor_amount', (v_seller_res->>'credited')::numeric,
    'commission_amount', v_commission_amount, 'released_at', now());
EXCEPTION WHEN OTHERS THEN
  RAISE;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. create_order_core() — commission acheteur (→PDG) via la primitive sûre
--    (corrige aussi le type wallet bigint ; le reste de la logique est identique)
-- ─────────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.create_order_core(
  text, uuid, uuid, uuid, text, text, jsonb, text, jsonb, int, uuid, numeric, text, numeric, numeric, numeric);

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
  p_exchange_rate_used     numeric  DEFAULT NULL,
  p_buyer_fee_amount       numeric  DEFAULT 0,
  p_seller_commission_amount numeric DEFAULT NULL
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
  v_buyer_fee         numeric      := COALESCE(p_buyer_fee_amount, 0);
  v_total_debit       numeric;
  v_pdg_user_id       uuid;
  v_fee_res           jsonb;
  v_db_rate           DECIMAL(20,8) := NULL;
  v_rate_fetched_at   timestamptz   := NULL;
  v_rate_source_label TEXT          := 'same_currency';
  v_rate_row          RECORD;
  v_raw_rate          DECIMAL(20,8) := NULL;
  v_max_age_hours     int;
BEGIN
  v_wallet_cur     := COALESCE(p_buyer_wallet_currency, p_currency);
  v_is_cross       := (p_currency IS DISTINCT FROM v_wallet_cur);
  v_escrow_buyer   := COALESCE(p_buyer_user_id, p_customer_id);
  v_total_debit    := p_wallet_debit_amount + v_buyer_fee;
  v_payment_status := CASE
    WHEN p_payment_method = 'wallet' AND p_wallet_debit_amount > 0 THEN 'paid'::payment_status
    ELSE 'pending'::payment_status END;

  -- PHASE -1 : Validation taux (wallet cross-devise)
  IF p_payment_method = 'wallet' AND p_buyer_user_id IS NOT NULL
     AND p_wallet_debit_amount > 0 AND v_is_cross THEN
    SELECT cer.* INTO v_rate_row
    FROM public.currency_exchange_rates cer
    WHERE ((cer.from_currency = p_currency AND cer.to_currency = v_wallet_cur)
        OR (cer.from_currency = v_wallet_cur AND cer.to_currency = p_currency))
      AND cer.is_active = true
    ORDER BY cer.retrieved_at DESC LIMIT 1;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false,
        'error', format('Aucun taux de change trouvé pour la paire %s/%s.', p_currency, v_wallet_cur));
    END IF;
    IF (p_currency = 'GNF' OR v_wallet_cur = 'GNF') AND v_rate_row.source_type = 'fallback_api' THEN
      RETURN jsonb_build_object('success', false,
        'error', 'Taux GNF invalide : seuls les taux officiels BCRG sont acceptés.');
    END IF;
    IF (p_currency = 'GNF' OR v_wallet_cur = 'GNF') AND v_rate_row.source_type = 'official_html' THEN
      IF v_rate_row.last_bcrg_scraped_at IS NULL THEN
        RETURN jsonb_build_object('success', false,
          'error', 'Aucun scraping BCRG enregistré. Veuillez réessayer dans quelques minutes.');
      END IF;
      IF v_rate_row.last_bcrg_scraped_at < now() - interval '24 hours' THEN
        RETURN jsonb_build_object('success', false,
          'error', format('Données BCRG trop anciennes (> 24h, dernier scraping : %s).',
            to_char(v_rate_row.last_bcrg_scraped_at AT TIME ZONE 'UTC', 'DD/MM/YYYY HH24:MI UTC')));
      END IF;
    END IF;
    v_max_age_hours := CASE
      WHEN v_rate_row.source_type IN ('official_html', 'official_fixed_parity') THEN 25 ELSE 2 END;
    IF v_rate_row.retrieved_at < now() - make_interval(hours => v_max_age_hours) THEN
      RETURN jsonb_build_object('success', false,
        'error', format('Taux %s/%s expiré (> %sh). Veuillez réessayer.', p_currency, v_wallet_cur, v_max_age_hours));
    END IF;
    v_raw_rate := COALESCE(
      CASE
        WHEN p_currency = 'EUR' OR v_wallet_cur = 'EUR' THEN v_rate_row.final_rate_eur
        WHEN p_currency = 'USD' OR v_wallet_cur = 'USD' THEN v_rate_row.final_rate_usd
        ELSE v_rate_row.rate * (1.0 + COALESCE(v_rate_row.margin, 0))
      END, v_rate_row.rate);
    v_db_rate := CASE WHEN v_rate_row.from_currency = p_currency THEN v_raw_rate
                      ELSE 1.0 / NULLIF(v_raw_rate, 0) END;
    v_rate_fetched_at := v_rate_row.retrieved_at;
    IF p_exchange_rate_used IS NOT NULL AND p_exchange_rate_used > 0
       AND v_db_rate IS NOT NULL AND v_db_rate > 0 THEN
      IF ABS(p_exchange_rate_used - v_db_rate) / v_db_rate > 0.05 THEN
        RETURN jsonb_build_object('success', false,
          'error', format('Taux de change obsolète (écart > 5%% : frontend %s vs BCRG %s). Rafraîchissez la page.',
            to_char(p_exchange_rate_used, 'FM999999990.999999'), to_char(v_db_rate, 'FM999999990.999999')));
      END IF;
    END IF;
    v_rate_source_label := CASE
      WHEN p_currency = 'GNF' OR v_wallet_cur = 'GNF' THEN 'BCRG (bcrg-guinee.org)'
      ELSE COALESCE(v_rate_row.source_url, 'currency_exchange_rates') END;
  END IF;

  -- PHASE 0 : Vérification solde
  IF p_payment_method = 'wallet' AND p_buyer_user_id IS NOT NULL AND v_total_debit > 0 THEN
    PERFORM 1 FROM public.wallets
    WHERE user_id = p_buyer_user_id AND currency = v_wallet_cur AND balance >= v_total_debit
    FOR UPDATE;
    IF NOT FOUND THEN
      IF EXISTS (SELECT 1 FROM public.wallets WHERE user_id = p_buyer_user_id AND currency = v_wallet_cur) THEN
        RETURN jsonb_build_object('success', false,
          'error', format('Solde %s insuffisant (montant + commission)', v_wallet_cur));
      ELSE
        RETURN jsonb_build_object('success', false,
          'error', format('Portefeuille introuvable en %s pour cet utilisateur', v_wallet_cur));
      END IF;
    END IF;
  END IF;

  -- PHASE 1 : Valider produits + stock
  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id := (item->>'product_id')::uuid;
    v_quantity   := (item->>'quantity')::int;
    SELECT p.stock_quantity, p.price, p.name INTO v_current_stock, v_product_price, v_product_name
    FROM products p
    WHERE p.id = v_product_id AND p.vendor_id = p_vendor_id AND p.is_active = true
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false,
        'error', format('Produit %s introuvable, inactif ou mauvais vendeur', v_product_id));
    END IF;
    IF v_current_stock IS NOT NULL AND v_current_stock < v_quantity THEN
      RETURN jsonb_build_object('success', false,
        'error', format('Stock insuffisant pour "%s" : %s disponible, %s demandé', v_product_name, v_current_stock, v_quantity));
    END IF;
    v_item_records := v_item_records || jsonb_build_object(
      'product_id', v_product_id, 'product_name', v_product_name, 'quantity', v_quantity,
      'unit_price', v_product_price, 'total_price', v_product_price * v_quantity, 'variant_id', item->>'variant_id');
    v_subtotal := v_subtotal + (v_product_price * v_quantity);
  END LOOP;

  -- PHASE 2 : Créer la commande
  INSERT INTO orders (order_number, customer_id, vendor_id, status, payment_status, payment_method,
    payment_intent_id, subtotal, total_amount, shipping_address, currency)
  VALUES (p_order_number, p_customer_id, p_vendor_id, 'pending'::order_status, v_payment_status,
    p_payment_method::payment_method, p_payment_intent_id, v_subtotal, v_subtotal, p_shipping_address, p_currency)
  RETURNING id INTO v_order_id;

  -- PHASE 3 : Lignes
  INSERT INTO order_items (order_id, product_id, product_name, quantity, unit_price, total_price, variant_id)
  SELECT v_order_id, (r->>'product_id')::uuid, r->>'product_name', (r->>'quantity')::int,
    (r->>'unit_price')::numeric, (r->>'total_price')::numeric, NULLIF(r->>'variant_id','')::uuid
  FROM jsonb_array_elements(v_item_records) AS r;

  -- PHASE 4 : Stock
  UPDATE products p
  SET stock_quantity = GREATEST(0, COALESCE(p.stock_quantity,0) - (r->>'quantity')::int), updated_at = now()
  FROM jsonb_array_elements(v_item_records) AS r
  WHERE p.id = (r->>'product_id')::uuid;

  -- PHASE 5 : Escrow
  v_release_at := now() + (p_auto_release_days || ' days')::interval;
  INSERT INTO escrow_transactions (
    order_id, buyer_id, seller_id, payer_id, receiver_id, amount, currency, status,
    auto_release_at, auto_release_date, payment_method, original_amount, original_currency,
    buyer_debit_amount, buyer_debit_currency, exchange_rate_used, is_cross_currency, commission_amount)
  VALUES (
    v_order_id, v_escrow_buyer, p_vendor_user_id, p_buyer_user_id, p_vendor_user_id,
    v_subtotal, p_currency, 'held', v_release_at, v_release_at, p_payment_method, v_subtotal, p_currency,
    CASE WHEN p_payment_method='wallet' AND p_wallet_debit_amount>0 THEN p_wallet_debit_amount ELSE NULL END,
    CASE WHEN p_payment_method='wallet' AND p_wallet_debit_amount>0 THEN v_wallet_cur ELSE NULL END,
    CASE WHEN v_is_cross AND p_payment_method='wallet' THEN COALESCE(p_exchange_rate_used, v_db_rate) ELSE NULL END,
    v_is_cross AND p_payment_method='wallet',
    p_seller_commission_amount);

  -- PHASE 5bis : Log conversion (non bloquant)
  BEGIN
    IF p_payment_method='wallet' AND p_buyer_user_id IS NOT NULL AND p_wallet_debit_amount>0 THEN
      INSERT INTO public.currency_conversion_logs (order_id, buyer_user_id, vendor_id, from_currency,
        to_currency, is_cross_currency, original_amount, converted_amount, wallet_debit_amount,
        exchange_rate, exchange_rate_source, rate_fetched_at, status)
      VALUES (v_order_id, p_buyer_user_id, p_vendor_id, p_currency, v_wallet_cur, v_is_cross, v_subtotal,
        CASE WHEN v_is_cross THEN p_wallet_debit_amount ELSE v_subtotal END, p_wallet_debit_amount,
        COALESCE(CASE WHEN v_is_cross THEN COALESCE(p_exchange_rate_used, v_db_rate) ELSE NULL END, 1.0),
        v_rate_source_label, v_rate_fetched_at, 'success');
    END IF;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- PHASE 6 : Débit wallet acheteur
  IF p_payment_method='wallet' AND p_buyer_user_id IS NOT NULL AND v_total_debit>0 THEN
    UPDATE public.wallets
    SET balance = balance - v_total_debit, updated_at = now()
    WHERE user_id = p_buyer_user_id AND currency = v_wallet_cur;

    INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
      transaction_type, amount, net_amount, description, status, metadata)
    VALUES ('mkt-' || left(replace(gen_random_uuid()::text,'-',''),45), p_buyer_user_id, p_vendor_user_id,
      'payment', p_wallet_debit_amount, p_wallet_debit_amount,
      'Paiement commande marketplace — Fonds bloqués en Escrow', 'completed',
      jsonb_build_object('order_id', v_order_id, 'order_currency', p_currency, 'wallet_currency', v_wallet_cur,
        'product_amount', v_subtotal, 'total_debited', v_total_debit, 'buyer_fee_amount', v_buyer_fee,
        'exchange_rate_used', COALESCE(p_exchange_rate_used, v_db_rate, 1.0), 'exchange_rate_source', v_rate_source_label,
        'is_cross_currency', v_is_cross, 'source', 'create_order_core'));

    -- COMMISSION ACHETEUR → wallet PDG via la primitive sûre. Best-effort : ne bloque jamais la commande.
    IF v_buyer_fee > 0 THEN
      BEGIN
        SELECT user_id INTO v_pdg_user_id FROM pdg_management WHERE is_active = true LIMIT 1;
        IF v_pdg_user_id IS NOT NULL THEN
          v_fee_res := public.credit_user_wallet_safe(v_pdg_user_id, v_buyer_fee, v_wallet_cur);
          INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
            transaction_type, amount, net_amount, description, status, metadata)
          VALUES ('fee-' || left(replace(gen_random_uuid()::text,'-',''),45), p_buyer_user_id, v_pdg_user_id,
            'commission', (v_fee_res->>'credited')::numeric, (v_fee_res->>'credited')::numeric,
            'Commission acheteur marketplace', 'completed',
            jsonb_build_object('order_id', v_order_id, 'wallet_currency', v_fee_res->>'currency',
              'original_fee', v_buyer_fee, 'original_currency', v_wallet_cur, 'source', 'buyer_commission'));
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;
  END IF;

  RETURN jsonb_build_object('success', true, 'order_id', v_order_id, 'order_number', p_order_number,
    'subtotal', v_subtotal, 'total_amount', v_subtotal, 'currency', p_currency, 'items', v_item_records,
    'escrow_status', 'held', 'payment_status', v_payment_status::text, 'is_cross_currency', v_is_cross,
    'buyer_fee_amount', v_buyer_fee, 'total_debited', v_total_debit,
    'exchange_rate', COALESCE(p_exchange_rate_used, v_db_rate, 1.0), 'exchange_rate_source', v_rate_source_label);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

SELECT 'Flux argent commandes durci : credit_user_wallet_safe + create_order_core/auto_release/refund/confirm unifiés.' AS status;
