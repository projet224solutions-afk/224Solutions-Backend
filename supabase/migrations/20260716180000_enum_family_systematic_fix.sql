-- ═══════════════════════════════════════════════════════════════════════════
-- CHASSE SYSTÉMATIQUE FAMILLE « text→enum sans cast » (16 juil 2026)
-- Méthode : plpgsql_check 2.7 passé sur les 1024 fonctions/triggers publics de
-- la PROD (fatal_errors=false) + filtre types enum applicatifs → 12 fonctions
-- mortes-nées, chacune PROUVÉE cassée par exécution réelle (BEGIN…ROLLBACK)
-- avant fix. Même famille que execute_atomic_deposit / create_pos_order_complete
-- / audit_role_change (certification 16/07).
-- Chaque fix = cast explicite ou label enum valide — AUCUN changement de logique.
-- ═══════════════════════════════════════════════════════════════════════════

-- 1) settle_payment_link_atomic — 22P02 prouvé : enum transaction_type sans label 'wallet'.
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
    transaction_id, sender_user_id, receiver_user_id, amount, transaction_type, status, currency, metadata
  ) VALUES (
    v_tx_id, p_buyer_id, p_seller_id, p_gross, 'payment'::public.transaction_type, 'completed', v_cur,
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

-- 2) prevent_role_self_escalation — 42883 statique : user_role = ANY(text[]).
CREATE OR REPLACE FUNCTION public.prevent_role_self_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller      uuid := auth.uid();
  v_caller_role text;
  -- Rôles qu'un utilisateur peut s'auto-attribuer (= inscription publique self-service)
  v_self_service text[] := ARRAY['client', 'vendeur', 'livreur', 'taxi', 'transitaire', 'prestataire'];
BEGIN
  -- Pas de changement de rôle → rien à contrôler.
  IF NEW.role IS NOT DISTINCT FROM OLD.role THEN
    RETURN NEW;
  END IF;

  -- Écritures backend (service_role) : auth.uid() est NULL → de confiance.
  IF v_caller IS NULL THEN
    RETURN NEW;
  END IF;

  -- Un admin/pdg/ceo peut attribuer n'importe quel rôle.
  SELECT role INTO v_caller_role FROM public.profiles WHERE id = v_caller;
  IF COALESCE(v_caller_role, '') IN ('admin', 'pdg', 'ceo') THEN
    RETURN NEW;
  END IF;

  -- Non-admin : uniquement vers un rôle d'inscription publique.
  IF NEW.role::text = ANY (v_self_service) THEN
    RETURN NEW;
  END IF;

  -- Tout autre rôle (agent, vendor_agent, restaurant_agent, syndicat, admin,
  -- pdg, ceo, actionnaire…) est refusé pour un appelant non-admin.
  RAISE EXCEPTION 'Auto-attribution du rôle "%" non autorisée (% -> %)',
    NEW.role, OLD.role, NEW.role
    USING ERRCODE = '42501';
END;
$function$
;

-- 3) force_credit_seller_wallet — 22P02 prouvé : 'credit' hors enum transaction_type.
CREATE OR REPLACE FUNCTION public.force_credit_seller_wallet(p_transaction_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_transaction RECORD;
  v_wallet_id UUID;
  v_balance_before DECIMAL(12,2);
  v_balance_after DECIMAL(12,2);
  v_wallet_transaction_id UUID;
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
    total_received = COALESCE(total_received, 0) + v_transaction.seller_net_amount,
    last_transaction_at = NOW(),
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

-- 4) publish_dropship_product — 22P02 prouvé : COALESCE(user_role, '') coerce '' en enum.
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
      COALESCE(dp.images, '[]'::jsonb), COALESCE(dp.stock_quantity, 0),
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

-- 5) apply_wallet_regularization — 42804 prouvé : CASE text inséré dans enum.
CREATE OR REPLACE FUNCTION public.apply_wallet_regularization(p_transaction_id text, p_wallet_id bigint, p_user_id uuid, p_delta numeric, p_currency text, p_description text, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_wallet      RECORD;
  v_new_balance numeric;
BEGIN
  -- Idempotence dure : la même clé ne s'applique qu'une fois (l'index unique
  -- protège aussi contre la course entre deux appels concurrents).
  IF EXISTS (SELECT 1 FROM public.wallet_transactions WHERE transaction_id = p_transaction_id) THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true, 'transaction_id', p_transaction_id);
  END IF;

  IF p_delta IS NULL OR p_delta = 0 THEN
    RAISE EXCEPTION 'Régularisation refusée : delta nul (%)', p_transaction_id;
  END IF;
  IF p_description IS NULL OR btrim(p_description) = '' THEN
    RAISE EXCEPTION 'Régularisation refusée : description obligatoire (%)', p_transaction_id;
  END IF;

  -- Verrou pessimiste : sérialise avec tout crédit/débit concurrent du wallet.
  SELECT * INTO v_wallet FROM public.wallets
  WHERE id = p_wallet_id AND user_id = p_user_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Wallet % introuvable pour l''utilisateur % (%)', p_wallet_id, p_user_id, p_transaction_id;
  END IF;
  IF COALESCE(v_wallet.currency, 'GNF') <> p_currency THEN
    RAISE EXCEPTION 'Devise % ≠ devise du wallet (%) — conversion à faire AVANT (%)',
      p_currency, COALESCE(v_wallet.currency, 'GNF'), p_transaction_id;
  END IF;
  IF p_delta < 0 AND COALESCE(v_wallet.balance, 0) + p_delta < 0 THEN
    RAISE EXCEPTION 'Reprise refusée : solde % + delta % < 0 (%)',
      COALESCE(v_wallet.balance, 0), p_delta, p_transaction_id;
  END IF;

  UPDATE public.wallets
  SET balance = COALESCE(balance, 0) + p_delta, updated_at = now()
  WHERE id = p_wallet_id
  RETURNING balance INTO v_new_balance;

  -- Trace dans la MÊME transaction : crédit = receiver_*, reprise = sender_*,
  -- montant toujours POSITIF (l'enum transaction_type n'a ni 'credit' ni 'debit').
  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_wallet_id, receiver_user_id, sender_wallet_id, sender_user_id,
    amount, fee, net_amount, currency, transaction_type, status, description, metadata)
  VALUES (
    p_transaction_id,
    CASE WHEN p_delta > 0 THEN p_wallet_id END,
    CASE WHEN p_delta > 0 THEN p_user_id END,
    CASE WHEN p_delta < 0 THEN p_wallet_id END,
    CASE WHEN p_delta < 0 THEN p_user_id END,
    ABS(p_delta), 0, ABS(p_delta), p_currency,
    (CASE WHEN p_delta > 0 THEN 'refund' ELSE 'withdrawal' END)::public.transaction_type,
    'completed', p_description,
    COALESCE(p_metadata, '{}'::jsonb)
      || jsonb_build_object('regularization', true, 'delta', p_delta, 'applied_at', now()));

  RETURN jsonb_build_object('success', true, 'transaction_id', p_transaction_id,
    'wallet_id', p_wallet_id, 'delta', p_delta, 'new_balance', v_new_balance);
END;
$function$
;

-- 6) migrate_existing_ids — 22P02 prouvé : label 'vendor' inexistant (le rôle est 'vendeur').
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

    RETURN QUERY SELECT 'user_ids'::TEXT, v_record.custom_id, v_new_id, 'migrated'::TEXT;
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

      RETURN QUERY SELECT 'profiles'::TEXT, v_record.public_id, v_new_id, 'migrated'::TEXT;
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

    RETURN QUERY SELECT 'vendors'::TEXT, v_record.public_id, v_new_id, 'migrated'::TEXT;
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

    RETURN QUERY SELECT 'products'::TEXT, v_record.public_id, v_new_id, 'migrated'::TEXT;
  END LOOP;

  -- Migrer les wallets
  FOR v_record IN
    SELECT id, public_id FROM public.wallets
    WHERE public_id IS NOT NULL AND NOT validate_standard_id(public_id)
    ORDER BY created_at
  LOOP
    v_new_id := generate_sequential_id('WLT');

    INSERT INTO public.id_migration_map (old_id, new_id, table_name, prefix)
    VALUES (v_record.public_id, v_new_id, 'wallets', 'WLT')
    ON CONFLICT DO NOTHING;

    RETURN QUERY SELECT 'wallets'::TEXT, v_record.public_id, v_new_id, 'migrated'::TEXT;
  END LOOP;

END;
$function$
;

-- 7) detect_user_anomalies — 22P02 + 42804 prouvés : label 'user' inexistant, public_id varchar vs text.
CREATE OR REPLACE FUNCTION public.detect_user_anomalies()
 RETURNS TABLE(user_id uuid, public_id text, anomaly_type text, details jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT 
    p.id as user_id,
    p.public_id::text,
    'MISSING_PUBLIC_ID'::TEXT as anomaly_type,
    jsonb_build_object('email', p.email, 'role', p.role) as details
  FROM profiles p
  WHERE p.public_id IS NULL OR p.public_id = '';

  RETURN QUERY
  SELECT 
    p.id as user_id,
    p.public_id::text,
    'ID_SYNC_MISMATCH'::TEXT as anomaly_type,
    jsonb_build_object(
      'profile_public_id', p.public_id::text,
      'user_ids_custom_id', ui.custom_id
    ) as details
  FROM profiles p
  LEFT JOIN user_ids ui ON ui.user_id = p.id
  WHERE p.public_id IS NOT NULL 
    AND ui.custom_id IS NOT NULL 
    AND p.public_id != ui.custom_id;

  RETURN QUERY
  SELECT 
    p.id as user_id,
    p.public_id::text,
    'ROLE_TABLE_MISMATCH'::TEXT as anomaly_type,
    jsonb_build_object('profile_role', p.role) as details
  FROM profiles p
  LEFT JOIN user_roles ur ON ur.user_id = p.id
  WHERE p.role IS NOT NULL 
    AND p.role::text != 'user'
    AND ur.id IS NULL;
END;
$function$
;

-- 8) detect_all_anomalies_optimized — 22P02 prouvé : 'refunded' hors enum order_status.
CREATE OR REPLACE FUNCTION public.detect_all_anomalies_optimized(p_domain text DEFAULT NULL::text)
 RETURNS TABLE(anomaly_type text, domain text, entity_id text, severity text, details jsonb, detected_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
BEGIN
  -- Stock anomalies
  IF p_domain IS NULL OR p_domain = 'INVENTORY' THEN
    RETURN QUERY
    SELECT 
      'STOCK_ANOMALY'::TEXT,
      'INVENTORY'::TEXT,
      s.product_id::TEXT,
      s.severity,
      jsonb_build_object(
        'product_name', s.product_name,
        'current_stock', s.current_stock,
        'recommendation', s.recommendation
      ),
      now()
    FROM detect_stock_anomalies_advanced() s
    WHERE s.severity IN ('CRITICAL', 'HIGH');
  END IF;

  -- Wallet anomalies
  IF p_domain IS NULL OR p_domain = 'WALLETS' THEN
    RETURN QUERY
    SELECT 
      'WALLET_ANOMALY'::TEXT,
      'WALLETS'::TEXT,
      w.wallet_id,
      w.severity,
      jsonb_build_object(
        'balance', w.current_balance,
        'anomaly_type', w.anomaly_type,
        'transactions_24h', w.transaction_count_24h
      ),
      now()
    FROM detect_wallet_anomalies_advanced() w
    WHERE w.severity IN ('CRITICAL', 'HIGH');
  END IF;

  -- Commandes impayées anciennes
  IF p_domain IS NULL OR p_domain = 'ORDERS' THEN
    RETURN QUERY
    SELECT 
      'UNPAID_ORDER'::TEXT,
      'ORDERS'::TEXT,
      o.id::TEXT,
      CASE 
        WHEN o.created_at < now() - interval '48 hours' THEN 'CRITICAL'
        WHEN o.created_at < now() - interval '24 hours' THEN 'HIGH'
        ELSE 'MEDIUM'
      END,
      jsonb_build_object(
        'order_number', o.order_number,
        'total_amount', o.total_amount,
        'hours_pending', EXTRACT(EPOCH FROM (now() - o.created_at)) / 3600
      ),
      now()
    FROM orders o
    WHERE o.payment_status = 'pending'
      AND o.status::text NOT IN ('cancelled', 'refunded')
      AND o.created_at < now() - interval '12 hours';
  END IF;
END;
$function$
;

-- 9) backfill_vendor_customer_links — 22P02 prouvé : 'refunded' hors enum order_status.
CREATE OR REPLACE FUNCTION public.backfill_vendor_customer_links()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_count int := 0;
BEGIN
  INSERT INTO vendor_customer_links (
    vendor_id, customer_user_id, source_type, linked_via,
    email, phone, full_name,
    last_purchase_at, total_orders, total_spent
  )
  SELECT 
    o.vendor_id,
    c.user_id,
    CASE 
      WHEN bool_or(o.source = 'pos') AND bool_or(o.source = 'online') THEN 'both'
      WHEN bool_or(o.source = 'pos') THEN 'physical'
      ELSE 'digital'
    END,
    CASE 
      WHEN bool_or(o.source = 'pos') THEN 'pos_order'
      ELSE 'marketplace_order'
    END,
    p.email,
    p.phone,
    COALESCE(p.first_name || ' ' || p.last_name, p.email),
    MAX(o.created_at),
    COUNT(o.id)::int,
    COALESCE(SUM(o.total_amount), 0)
  FROM orders o
  JOIN customers c ON c.id = o.customer_id
  JOIN profiles p ON p.id = c.user_id
  WHERE o.vendor_id IS NOT NULL
    AND o.status::text NOT IN ('cancelled', 'refunded')
  GROUP BY o.vendor_id, c.user_id, p.email, p.phone, p.first_name, p.last_name
  ON CONFLICT (vendor_id, customer_user_id) DO UPDATE SET
    last_purchase_at = GREATEST(vendor_customer_links.last_purchase_at, EXCLUDED.last_purchase_at),
    total_orders = EXCLUDED.total_orders,
    total_spent = EXCLUDED.total_spent,
    email = COALESCE(EXCLUDED.email, vendor_customer_links.email),
    phone = COALESCE(EXCLUDED.phone, vendor_customer_links.phone),
    full_name = COALESCE(EXCLUDED.full_name, vendor_customer_links.full_name),
    updated_at = now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$
;

-- 10) get_user_permissions — 42883 prouvé : roles.name (varchar) = profiles.role (enum).
CREATE OR REPLACE FUNCTION public.get_user_permissions(p_user_id uuid)
 RETURNS TABLE(action text, allowed boolean, role_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
BEGIN
  RETURN QUERY
  SELECT 
    p.action::TEXT,
    p.allowed,
    r.name::TEXT
  FROM profiles pr
  JOIN roles r ON r.name = pr.role::text
  JOIN permissions p ON p.role_id = r.id
  WHERE pr.id = p_user_id;
END;
$function$
;

-- 11) get_online_users — 42804 prouvé : user_presence_status renvoyé dans une colonne varchar.
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
        up.custom_status,
        up.last_seen,
        up.last_active,
        (up.status IN ('online', 'busy', 'in_call') AND up.last_active > NOW() - INTERVAL '45 seconds') AS is_online
    FROM user_presence up
    WHERE (p_user_ids IS NULL OR up.user_id = ANY(p_user_ids))
      AND up.status != 'offline';
END;
$function$
;

-- 12) detect_order_anomalies — 42703 + 42804 prouvés : colonne paid_at inexistante (proxy updated_at), status enum vs text.
CREATE OR REPLACE FUNCTION public.detect_order_anomalies()
 RETURNS TABLE(order_id uuid, order_number text, anomaly_type text, current_status text, expected_status text, details jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT 
    o.id as order_id,
    o.order_number,
    'STALE_PAID_ORDER'::TEXT as anomaly_type,
    o.status::text as current_status,
    'processing'::TEXT as expected_status,
    jsonb_build_object(
      'last_update_at', o.updated_at, -- orders n'a pas de paid_at : updated_at en proxy
      'days_stale', EXTRACT(DAY FROM NOW() - o.updated_at)
    ) as details
  FROM orders o
  WHERE o.payment_status = 'paid' 
    AND o.status = 'pending'
    AND o.updated_at < NOW() - INTERVAL '24 hours';

  RETURN QUERY
  SELECT 
    o.id as order_id,
    o.order_number,
    'DELIVERED_UNPAID'::TEXT as anomaly_type,
    o.status::text as current_status,
    'paid_required'::TEXT as expected_status,
    jsonb_build_object(
      'payment_status', o.payment_status,
      'delivered_at', o.updated_at
    ) as details
  FROM orders o
  WHERE o.status = 'delivered' 
    AND o.payment_status != 'paid';
END;
$function$
;

