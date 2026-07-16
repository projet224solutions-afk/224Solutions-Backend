-- ═══════════════════════════════════════════════════════════════════════════
-- CHASSE enum — 2e passe (16 juil 2026) : défauts PROFONDS des mêmes fonctions,
-- révélés par le re-check une fois la famille enum corrigée (la 1re erreur
-- fatale masquait les suivantes). Chacun re-prouvé par plpgsql_check + appel réel.
--  • settle_payment_link_atomic : INSERT sans net_amount (NOT NULL) → 23502
--  • force_credit_seller_wallet : v_wallet_id UUID vs wallets.id BIGINT → 42883
--  • get_online_users : custom_status varchar vs colonne OUT text → 42804
--  • migrate_existing_ids : varchar vs text (RETURN QUERY) + boucle sur
--    wallets.public_id (colonne INEXISTANTE) → 42703
--  • publish_dropship_product : COALESCE(text[], '[]'::jsonb) → 42804
-- ═══════════════════════════════════════════════════════════════════════════

-- 1) settle_payment_link_atomic — 23502 prouvé (appel réel) : net_amount NOT NULL absent de l'INSERT.
CREATE OR REPLACE FUNCTION public.settle_payment_link_atomic(p_buyer_id uuid, p_seller_id uuid, p_gross numeric, p_fee numeric, p_currency text, p_reference text, p_idempotency_key text, p_description text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_buyer_wallet     public.wallets%ROWTYPE;
  v_seller_wallet_id bigint;
  v_net              numeric;
  v_tx_id            text;
  v_cur              text := upper(coalesce(nullif(trim(p_currency), ''), 'GNF'));
  v_link             public.payment_links%ROWTYPE;
  v_item             jsonb;
  v_pid              uuid;
  v_qty              numeric;
BEGIN
  IF p_gross IS NULL OR p_gross <= 0 THEN RAISE EXCEPTION 'BAD_AMOUNT'; END IF;
  IF p_fee IS NULL OR p_fee < 0 OR p_fee > p_gross THEN RAISE EXCEPTION 'BAD_FEE'; END IF;
  IF p_buyer_id = p_seller_id THEN RAISE EXCEPTION 'OWN_LINK'; END IF;
  v_net := p_gross - p_fee;

  -- IDEMPOTENCE (insert-first = verrou). Doublon/rejeu → on ne re-règle PAS.
  -- (Rollback de toute la transaction = la clé est aussi annulée → un vrai rejeu peut réussir.)
  BEGIN
    INSERT INTO public.wallet_idempotency_keys (idempotency_key, user_id, operation)
    VALUES (p_idempotency_key, p_buyer_id, 'payment_link');
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('success', true, 'already_processed', true);
  END;

  -- Verrou acheteur
  SELECT * INTO v_buyer_wallet
  FROM public.wallets WHERE user_id = p_buyer_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BUYER_WALLET_NOT_FOUND'; END IF;
  IF v_buyer_wallet.is_blocked THEN RAISE EXCEPTION 'WALLET_BLOCKED'; END IF;
  IF v_buyer_wallet.balance < p_gross THEN RAISE EXCEPTION 'INSUFFICIENT_FUNDS'; END IF;

  -- Verrou vendeur
  SELECT id INTO v_seller_wallet_id
  FROM public.wallets WHERE user_id = p_seller_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF v_seller_wallet_id IS NULL THEN RAISE EXCEPTION 'SELLER_WALLET_NOT_FOUND'; END IF;

  -- Mouvements ATOMIQUES : débit acheteur (brut) + crédit vendeur (net).
  UPDATE public.wallets SET balance = balance - p_gross, updated_at = now() WHERE id = v_buyer_wallet.id;
  UPDATE public.wallets SET balance = balance + v_net,  updated_at = now() WHERE id = v_seller_wallet_id;

  v_tx_id := 'PLK-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text), 1, 6);

  INSERT INTO public.wallet_transactions (
    transaction_id, sender_user_id, receiver_user_id, amount, fee, net_amount, transaction_type, status, currency, metadata
  ) VALUES (
    v_tx_id, p_buyer_id, p_seller_id, p_gross, p_fee, v_net, 'payment'::public.transaction_type, 'completed', v_cur,
    jsonb_build_object(
      'description', p_description, 'transaction_type', 'payment_link',
      'fee', p_fee, 'net_amount', v_net, 'reference', p_reference,
      'idempotency_key', p_idempotency_key, 'atomic', true
    )
  );

  -- ── DANS LA MÊME TRANSACTION : marquer le lien payé + décrémenter le stock ──
  -- p_reference = payment_id (humain) ou id (UUID en repli).
  SELECT * INTO v_link FROM public.payment_links
    WHERE payment_id = p_reference OR id::text = p_reference
    ORDER BY created_at DESC LIMIT 1 FOR UPDATE;

  IF FOUND THEN
    -- Décrément stock (idempotent via le flag metadata.stock_consumed)
    IF NOT COALESCE((v_link.metadata->>'stock_consumed')::boolean, false) THEN
      FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(v_link.metadata->'items', '[]'::jsonb)) LOOP
        v_pid := NULLIF(v_item->>'product_id', '')::uuid;
        v_qty := COALESCE((v_item->>'qty')::numeric, 1);
        IF v_pid IS NOT NULL AND v_qty > 0 THEN
          UPDATE public.products
             SET stock_quantity = GREATEST(0, COALESCE(stock_quantity, 0) - v_qty), updated_at = now()
           WHERE id = v_pid;
        END IF;
      END LOOP;
    END IF;

    UPDATE public.payment_links
       SET status = 'success', paid_at = now(), payment_method = 'wallet',
           transaction_id = v_tx_id, wallet_transaction_id = v_tx_id, wallet_credit_status = 'credited',
           gross_amount = p_gross, net_amount = v_net, platform_fee = p_fee,
           use_count = COALESCE(use_count, 0) + 1,
           metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('stock_consumed', true),
           updated_at = now()
     WHERE id = v_link.id;
  END IF;

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id, 'net_amount', v_net, 'fee', p_fee);
END;
$function$
;

-- 2) force_credit_seller_wallet — 42883/42804 : variables UUID pour des id BIGINT.
CREATE OR REPLACE FUNCTION public.force_credit_seller_wallet(p_transaction_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_transaction RECORD;
  v_wallet_id BIGINT;
  v_balance_before DECIMAL(12,2);
  v_balance_after DECIMAL(12,2);
  v_wallet_transaction_id BIGINT;
BEGIN
  SELECT * INTO v_transaction
  FROM stripe_transactions
  WHERE id = p_transaction_id AND status = 'SUCCEEDED';
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transaction not found or not succeeded');
  END IF;
  
  IF EXISTS (
    SELECT 1 FROM wallet_transactions
    WHERE metadata->>'stripe_payment_intent_id' = v_transaction.stripe_payment_intent_id
      AND transaction_type = 'card_payment'
  ) THEN
    RETURN jsonb_build_object('success', true, 'message', 'Wallet already credited');
  END IF;
  
  SELECT id, balance INTO v_wallet_id, v_balance_before
  FROM wallets WHERE user_id = v_transaction.seller_id;
  
  IF NOT FOUND THEN
    INSERT INTO wallets (user_id, balance, currency)
    VALUES (v_transaction.seller_id, 0, v_transaction.currency)
    RETURNING id, balance INTO v_wallet_id, v_balance_before;
  END IF;
  
  UPDATE wallets
  SET 
    balance = balance + v_transaction.seller_net_amount,
    updated_at = NOW()
  WHERE id = v_wallet_id
  RETURNING balance INTO v_balance_after;
  
  INSERT INTO wallet_transactions (
    transaction_id, receiver_wallet_id, amount, fee, net_amount, currency,
    transaction_type, status, description, metadata
  ) VALUES (
    'STRIPE-' || UPPER(SUBSTRING(MD5(RANDOM()::TEXT), 1, 10)),
    v_wallet_id,
    v_transaction.seller_net_amount,
    0,
    v_transaction.seller_net_amount,
    v_transaction.currency,
    'card_payment',
    'completed',
    'Paiement carte reçu - Commande #' || COALESCE(v_transaction.order_id::TEXT, 'N/A'),
    jsonb_build_object(
      'stripe_transaction_id', p_transaction_id,
      'stripe_payment_intent_id', v_transaction.stripe_payment_intent_id,
      'source', 'stripe_payment',
      'seller_id', v_transaction.seller_id,
      'balance_before', v_balance_before,
      'balance_after', v_balance_after
    )
  )
  RETURNING id INTO v_wallet_transaction_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'wallet_id', v_wallet_id,
    'amount_credited', v_transaction.seller_net_amount,
    'balance_before', v_balance_before,
    'balance_after', v_balance_after,
    'wallet_transaction_id', v_wallet_transaction_id
  );
END;
$function$
;

-- 3) get_online_users — 42804 : custom_status varchar(100) vs OUT text.
CREATE OR REPLACE FUNCTION public.get_online_users(p_user_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS TABLE(user_id uuid, status character varying, current_device character varying, custom_status text, last_seen timestamp with time zone, last_active timestamp with time zone, is_online boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        up.user_id,
        up.status::character varying,
        up.current_device,
        up.custom_status::text,
        up.last_seen,
        up.last_active,
        (up.status IN ('online', 'busy', 'in_call') AND up.last_active > NOW() - INTERVAL '45 seconds') AS is_online
    FROM user_presence up
    WHERE (p_user_ids IS NULL OR up.user_id = ANY(p_user_ids))
      AND up.status != 'offline';
END;
$function$
;

-- 4) migrate_existing_ids — 42804 varchar vs text + 42703 wallets.public_id inexistante.
CREATE OR REPLACE FUNCTION public.migrate_existing_ids()
 RETURNS TABLE(table_name text, old_id text, new_id text, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_record RECORD;
  v_new_id TEXT;
  v_prefix VARCHAR(3);
BEGIN
  -- Migrer les user_ids (custom_id)
  FOR v_record IN 
    SELECT ui.custom_id, ui.user_id, p.role
    FROM public.user_ids ui
    LEFT JOIN public.profiles p ON p.id = ui.user_id
    WHERE ui.custom_id IS NOT NULL
    AND NOT validate_standard_id(ui.custom_id)
    ORDER BY ui.created_at
  LOOP
    -- Déterminer le préfixe selon le rôle
    v_prefix := CASE 
      WHEN v_record.role::text = 'vendeur' THEN 'VND'
      WHEN v_record.role::text IN ('driver', 'livreur', 'taxi') THEN 'DRV'
      WHEN v_record.role::text = 'agent' THEN 'AGT'
      WHEN v_record.role::text = 'pdg' THEN 'PDG'
      ELSE 'USR'
    END;

    v_new_id := generate_sequential_id(v_prefix);

    -- Enregistrer le mapping
    INSERT INTO public.id_migration_map (old_id, new_id, table_name, prefix)
    VALUES (v_record.custom_id, v_new_id, 'user_ids', v_prefix)
    ON CONFLICT DO NOTHING;

    RETURN QUERY SELECT 'user_ids'::TEXT, v_record.custom_id::text, v_new_id, 'migrated'::TEXT;
  END LOOP;

  -- Migrer les profiles (public_id et custom_id)
  FOR v_record IN
    SELECT id, public_id, custom_id, role
    FROM public.profiles
    WHERE (public_id IS NOT NULL AND NOT validate_standard_id(public_id))
       OR (custom_id IS NOT NULL AND NOT validate_standard_id(custom_id))
    ORDER BY created_at
  LOOP
    v_prefix := CASE 
      WHEN v_record.role::text = 'vendeur' THEN 'VND'
      WHEN v_record.role::text IN ('driver', 'livreur', 'taxi') THEN 'DRV'
      WHEN v_record.role::text = 'agent' THEN 'AGT'
      WHEN v_record.role::text = 'pdg' THEN 'PDG'
      ELSE 'USR'
    END;

    v_new_id := generate_sequential_id(v_prefix);

    IF v_record.public_id IS NOT NULL THEN
      INSERT INTO public.id_migration_map (old_id, new_id, table_name, prefix)
      VALUES (v_record.public_id, v_new_id, 'profiles', v_prefix)
      ON CONFLICT DO NOTHING;

      RETURN QUERY SELECT 'profiles'::TEXT, v_record.public_id::text, v_new_id, 'migrated'::TEXT;
    END IF;
  END LOOP;

  -- Migrer les vendors
  FOR v_record IN
    SELECT id, public_id FROM public.vendors
    WHERE public_id IS NOT NULL AND NOT validate_standard_id(public_id)
    ORDER BY created_at
  LOOP
    v_new_id := generate_sequential_id('VND');

    INSERT INTO public.id_migration_map (old_id, new_id, table_name, prefix)
    VALUES (v_record.public_id, v_new_id, 'vendors', 'VND')
    ON CONFLICT DO NOTHING;

    RETURN QUERY SELECT 'vendors'::TEXT, v_record.public_id::text, v_new_id, 'migrated'::TEXT;
  END LOOP;

  -- Migrer les products
  FOR v_record IN
    SELECT id, public_id FROM public.products
    WHERE public_id IS NOT NULL AND NOT validate_standard_id(public_id)
    ORDER BY created_at
  LOOP
    v_new_id := generate_sequential_id('PRD');

    INSERT INTO public.id_migration_map (old_id, new_id, table_name, prefix)
    VALUES (v_record.public_id, v_new_id, 'products', 'PRD')
    ON CONFLICT DO NOTHING;

    RETURN QUERY SELECT 'products'::TEXT, v_record.public_id::text, v_new_id, 'migrated'::TEXT;
  END LOOP;

  -- (Boucle wallets SUPPRIMÉE : la table wallets n'a PAS de colonne public_id —
  -- la version d'origine plantait en 42703 dès qu'elle l'atteignait.)

END;
$function$
;

-- 5) publish_dropship_product — 42804 : products.images est text[], pas jsonb.
CREATE OR REPLACE FUNCTION public.publish_dropship_product(p_dropship_id uuid, p_actor_user_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  dp            public.dropship_products%ROWTYPE;
  v_vendor_id   uuid;
  v_vendor_user uuid;
  v_currency    text;
  v_name        text;
  v_price       numeric;
  v_product_id  uuid;
  v_action      text;
  v_is_admin    boolean;
BEGIN
  SELECT * INTO dp FROM public.dropship_products WHERE id = p_dropship_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DROPSHIP_PRODUCT_NOT_FOUND'; END IF;

  v_vendor_id := public.resolve_vendor_id(dp.vendor_id);
  IF v_vendor_id IS NULL THEN RAISE EXCEPTION 'VENDOR_NOT_RESOLVED'; END IF;
  SELECT user_id INTO v_vendor_user FROM public.vendors WHERE id = v_vendor_id;

  -- Contrôle de propriété : l'acteur doit être le vendeur OU un admin/pdg.
  IF p_actor_user_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = p_actor_user_id AND lower(COALESCE(role::text,'')) IN ('admin','pdg','ceo')
    ) INTO v_is_admin;
    IF NOT v_is_admin AND p_actor_user_id <> v_vendor_user AND p_actor_user_id <> dp.vendor_id THEN
      RAISE EXCEPTION 'NOT_OWNER';
    END IF;
  END IF;

  v_name     := COALESCE(NULLIF(btrim(dp.title), ''), NULLIF(btrim(dp.product_name), ''), 'Produit importé');
  v_price    := COALESCE(dp.selling_price, dp.cost_price, 0);
  v_currency := COALESCE(NULLIF(dp.selling_currency, ''), NULLIF(dp.cost_currency, ''), 'USD');

  IF v_price <= 0 THEN RAISE EXCEPTION 'INVALID_SELLING_PRICE'; END IF;

  -- 1) Re-publication : le miroir existe déjà → mise à jour (idempotent).
  IF dp.published_product_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.products WHERE id = dp.published_product_id) THEN
    UPDATE public.products SET
      name           = v_name,
      description     = dp.description,
      price           = v_price,
      currency        = v_currency,
      cost_price      = dp.cost_price,
      images          = COALESCE(dp.images, images),
      stock_quantity  = COALESCE(dp.stock_quantity, stock_quantity),
      is_active       = COALESCE(dp.is_available, true),
      updated_at      = now()
    WHERE id = dp.published_product_id;
    v_product_id := dp.published_product_id;
    v_action := 'updated';
  ELSE
    -- 2) Première publication : créer le produit catalogue.
    INSERT INTO public.products (
      vendor_id, name, description, price, currency, cost_price,
      images, stock_quantity, is_active, section
    ) VALUES (
      v_vendor_id, v_name, dp.description, v_price, v_currency, dp.cost_price,
      COALESCE(dp.images, '{}'::text[]), COALESCE(dp.stock_quantity, 0),
      COALESCE(dp.is_available, true), 'dropshipping'
    )
    RETURNING id INTO v_product_id;
    v_action := 'created';
  END IF;

  -- 3) Lier + marquer publié.
  UPDATE public.dropship_products
  SET published_product_id = v_product_id,
      is_published = true,
      is_active = true
  WHERE id = p_dropship_id;

  RETURN jsonb_build_object(
    'success', true, 'action', v_action,
    'product_id', v_product_id, 'dropship_id', p_dropship_id,
    'vendor_id', v_vendor_id, 'price', v_price, 'currency', v_currency
  );
END;
$function$
;

