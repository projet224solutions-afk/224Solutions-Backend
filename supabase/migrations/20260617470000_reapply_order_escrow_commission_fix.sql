-- ============================================================================
-- 🔧 CORRECTIF FUITE COMMISSION MARKETPLACE — réinstalle les fonctions correctes.
--
-- Constat (données live) : un achat retenait le TOTAL (frais inclus) en escrow,
-- commission_amount=NULL, et libérait au vendeur via une ANCIENNE fonction (fallback
-- 2,5%) → frais acheteur + 5% commission vendeur NON prélevés (vendeur sur-payé).
--
-- Cause : la base de prod tourne des versions ANCIENNES de create_order_core /
-- release_escrow_to_seller / auto-release (drift) alors que le code corrigé est bon.
--
-- Ce fichier = concaténation VERBATIM (idempotente, CREATE OR REPLACE) des 3 migrations
-- correctes, pour remettre la prod à la bonne version EN UNE FOIS :
--   1) 20260607210000 — create_order_core (escrow = SOUS-TOTAL, frais acheteur→PDG, commission vendeur stockée)
--   2) 20260608130000 — primitive de libération unifiée + confirm/auto-release
--   3) 20260608170000 — release_escrow_to_seller (vendeur NET + commission→PDG + ligne d'historique)
--
-- ⚠️ Après application : REDÉPLOYER le backend (orders.routes.ts envoie p_seller_commission_amount).
--    Puis refaire une commande test : escrow.amount=sous-total, commission_amount=5%, crédit PDG 'commission'.
-- ============================================================================

-- ─────────── [1/3] 20260607210000_fix_order_tx_currency.sql ───────────
-- 🩹 CORRECTIF AFFICHAGE — transactions de commande affichées « -0,01 € » au lieu du vrai montant.
--
-- CAUSE : wallets_transactions.currency a un DEFAULT 'GNF'. Dans create_order_core, les inserts du
-- paiement et de la commission ne renseignaient PAS la colonne currency → elle valait 'GNF' alors
-- que le montant est dans la devise du wallet acheteur (ex. EUR). L'historique priorise la colonne
-- (tx.currency) → 76,22 EUR étiqueté GNF → converti → 0,01 €.
--
-- FIX : renseigner explicitement currency dans les 2 inserts :
--   • paiement   → devise du wallet acheteur (v_wallet_cur)
--   • commission → devise du wallet acheteur (vue acheteur : ce qu'il a payé), metadata = crédit PDG.
-- Seul ce détail change ; toute la logique (atomicité, primitive sûre) reste identique.

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

    -- ✚ currency = devise du wallet acheteur (sinon DEFAULT 'GNF' → affichage faux 0,01 €)
    INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
      transaction_type, amount, net_amount, currency, description, status, metadata)
    VALUES ('mkt-' || left(replace(gen_random_uuid()::text,'-',''),45), p_buyer_user_id, p_vendor_user_id,
      'payment', p_wallet_debit_amount, p_wallet_debit_amount, v_wallet_cur,
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
          -- Vue ACHETEUR : montant = ce qu'il a payé (v_buyer_fee dans SA devise). metadata = crédit PDG réel.
          INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
            transaction_type, amount, net_amount, currency, description, status, metadata)
          VALUES ('fee-' || left(replace(gen_random_uuid()::text,'-',''),45), p_buyer_user_id, v_pdg_user_id,
            'commission', v_buyer_fee, v_buyer_fee, v_wallet_cur,
            'Commission acheteur marketplace', 'completed',
            jsonb_build_object('order_id', v_order_id, 'wallet_currency', v_wallet_cur,
              'original_fee', v_buyer_fee, 'original_currency', v_wallet_cur,
              'pdg_credited', (v_fee_res->>'credited')::numeric, 'pdg_currency', v_fee_res->>'currency',
              'source', 'buyer_commission'));
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

SELECT 'create_order_core : currency renseignée sur paiement + commission (fin du -0,01 €).' AS status;

-- ─────────── [2/3] 20260608130000_unify_escrow_release_primitive.sql ───────────
-- 🧱🧱 DURCISSEMENT BÉTON DE LA LIBÉRATION ESCROW — primitive unique, atomique, idempotente
--
-- Avant : 3 implémentations de la libération vendeur (confirm_delivery_and_release_escrow,
-- auto_release_escrows, job escrow.auto-release) dupliquaient le calcul commission + crédit + ledger,
-- avec des risques : pas de verrou (double-libération possible), atomicité partielle (job = plusieurs
-- appels séparés), divergence de logique. Chaque bug devait être corrigé à 3 endroits.
--
-- Après : UNE primitive canonique release_escrow_to_seller(escrow_id, reason) :
--   • verrou FOR UPDATE sur l'escrow → impossible de libérer deux fois en concurrence,
--   • idempotente : si déjà libéré → renvoie {skipped:true} sans rien faire,
--   • crédit vendeur + commission PDG via credit_user_wallet_safe (CONVERSION garantie),
--   • ligne d'historique en devise escrow (net = amount - fee → contrainte respectée),
--   • le tout dans UNE transaction.
-- confirm_delivery_and_release_escrow et auto_release_escrows ne font plus que l'autorisation /
-- l'éligibilité puis appellent la primitive. Le job backend l'appelle aussi (cf. jobQueue.ts).

-- ───────────────────────── PRIMITIVE CANONIQUE ─────────────────────────
CREATE OR REPLACE FUNCTION public.release_escrow_to_seller(
  p_escrow_id uuid,
  p_reason    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow        RECORD;
  v_commission    numeric;
  v_vendor_amount numeric;
  v_cur           text;
  v_seller        uuid;
  v_pdg           uuid;
  v_seller_res    jsonb;
  v_wallet_id     bigint;
BEGIN
  -- Verrou : sérialise les libérations concurrentes du même escrow
  SELECT * INTO v_escrow FROM public.escrow_transactions WHERE id = p_escrow_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Escrow introuvable');
  END IF;

  -- Idempotent : déjà libéré/remboursé → ne rien faire
  IF v_escrow.status NOT IN ('pending', 'held') THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'status', v_escrow.status);
  END IF;

  v_cur           := COALESCE(v_escrow.currency, 'GNF');
  v_seller        := COALESCE(v_escrow.receiver_id, v_escrow.seller_id);
  IF v_seller IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendeur manquant sur l''escrow');
  END IF;
  v_commission    := COALESCE(NULLIF(v_escrow.commission_amount, 0), v_escrow.amount * 0.025);
  v_vendor_amount := v_escrow.amount - v_commission;

  -- Crédit vendeur (net) + commission PDG, CONVERTIS dans la devise de chaque wallet
  v_seller_res := public.credit_user_wallet_safe(v_seller, v_vendor_amount, v_cur);
  v_wallet_id  := (v_seller_res->>'wallet_id')::bigint;

  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, v_cur);
  END IF;

  -- Statut escrow
  UPDATE public.escrow_transactions
  SET status = 'released', released_at = now(), commission_amount = v_commission, updated_at = now()
  WHERE id = p_escrow_id;

  -- Ligne d'historique EN DEVISE ESCROW (net = amount - fee). Montant converti dans metadata.
  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_wallet_id, receiver_user_id, amount, fee, net_amount, currency,
    transaction_type, status, description, metadata)
  VALUES (
    generate_transaction_id(), v_wallet_id, v_seller, v_escrow.amount, v_commission, v_vendor_amount, v_cur,
    'escrow_release', 'completed', 'Fonds escrow libérés',
    jsonb_build_object('escrow_id', p_escrow_id, 'order_id', v_escrow.order_id, 'commission', v_commission,
      'credited', (v_seller_res->>'credited')::numeric, 'credited_currency', v_seller_res->>'currency',
      'reason', p_reason, 'original_currency', v_cur));

  RETURN jsonb_build_object('success', true, 'escrow_id', p_escrow_id, 'vendor_amount', v_vendor_amount,
    'credited', (v_seller_res->>'credited')::numeric, 'credited_currency', v_seller_res->>'currency',
    'commission_amount', v_commission);
END;
$$;

REVOKE ALL ON FUNCTION public.release_escrow_to_seller(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.release_escrow_to_seller(uuid, text) TO service_role;

-- ───────────── confirm_delivery_and_release_escrow → auth + primitive ─────────────
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
  v_payer  uuid;
  v_buyer  uuid;
  v_status text;
  v_res    jsonb;
BEGIN
  SELECT payer_id, buyer_id, status INTO v_payer, v_buyer, v_status
  FROM public.escrow_transactions WHERE id = p_escrow_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction escrow introuvable';
  END IF;
  IF COALESCE(v_payer, v_buyer) <> p_customer_id THEN
    RAISE EXCEPTION 'Non autorisé: vous n''êtes pas le client de cette transaction';
  END IF;

  v_res := public.release_escrow_to_seller(p_escrow_id, 'customer_confirmation');

  -- Déjà libéré (idempotent) → succès
  IF COALESCE((v_res->>'skipped')::boolean, false) THEN
    RETURN json_build_object('success', true, 'already_released', true, 'escrow_id', p_escrow_id);
  END IF;
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION '%', COALESCE(v_res->>'error', 'Échec de la libération');
  END IF;

  -- Notes + journal (best-effort)
  UPDATE public.escrow_transactions SET notes = COALESCE(p_notes, notes) WHERE id = p_escrow_id;
  BEGIN
    INSERT INTO public.escrow_logs (escrow_id, action, performed_by, note)
    VALUES (p_escrow_id, 'customer_release', p_customer_id, p_notes);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN json_build_object('success', true, 'escrow_id', p_escrow_id,
    'vendor_amount', (v_res->>'vendor_amount')::numeric,
    'credited', (v_res->>'credited')::numeric, 'credited_currency', v_res->>'credited_currency',
    'commission_amount', (v_res->>'commission_amount')::numeric, 'released_at', now());
END;
$$;

-- ───────────── auto_release_escrows → éligibilité + primitive ─────────────
CREATE OR REPLACE FUNCTION public.auto_release_escrows()
RETURNS TABLE(escrow_id uuid, success boolean, message text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id  uuid;
  v_res jsonb;
BEGIN
  FOR v_id IN
    SELECT et.id
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
      v_res     := public.release_escrow_to_seller(v_id, 'auto_release_j7');
      escrow_id := v_id;
      success   := COALESCE((v_res->>'success')::boolean, false);
      message   := COALESCE(v_res->>'error',
                     CASE WHEN COALESCE((v_res->>'skipped')::boolean, false) THEN 'skipped' ELSE 'released' END);
      RETURN NEXT;
    EXCEPTION WHEN OTHERS THEN
      escrow_id := v_id; success := false; message := SQLERRM; RETURN NEXT;
    END;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.auto_release_escrows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.auto_release_escrows() TO service_role;

SELECT 'Libération escrow unifiée : primitive release_escrow_to_seller (FOR UPDATE + idempotente + conversion + atomique).' AS status;

-- ─────────── [3/3] 20260608170000_escrow_commission_ledger_and_leak_check.sql ───────────
-- 🩹 (1) Commission vendeur (libération escrow) tracée + (2) nouveau contrôle de surveillance "fuite escrow"
--
-- 1. release_escrow_to_seller créditait la commission PDG via credit_user_wallet_safe SANS ligne
--    d'historique → invisible dans l'historique PDG. On ajoute une ligne wallet_transactions
--    (type=commission, "Commission vendeur (libération escrow)") en devise escrow (net=amount),
--    montant converti dans metadata.credited.
-- 2. escrow_monitor_report : nouveau contrôle escrow_amount_mismatch = escrow dont amount > subtotal
--    de la commande (la commission acheteur s'est glissée dans l'escrow → vendeur sur-payé = fuite).
--    Le bug est corrigé côté backend (escrow.amount = subtotal), ce contrôle détecte toute régression.

-- ───────────── release_escrow_to_seller (+ ligne commission PDG) ─────────────
CREATE OR REPLACE FUNCTION public.release_escrow_to_seller(
  p_escrow_id uuid,
  p_reason    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow        RECORD;
  v_commission    numeric;
  v_vendor_amount numeric;
  v_cur           text;
  v_seller        uuid;
  v_pdg           uuid;
  v_seller_res    jsonb;
  v_pdg_res       jsonb;
  v_wallet_id     bigint;
BEGIN
  SELECT * INTO v_escrow FROM public.escrow_transactions WHERE id = p_escrow_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Escrow introuvable');
  END IF;

  IF v_escrow.status NOT IN ('pending', 'held') THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'status', v_escrow.status);
  END IF;

  v_cur    := COALESCE(v_escrow.currency, 'GNF');
  v_seller := COALESCE(v_escrow.receiver_id, v_escrow.seller_id);
  IF v_seller IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendeur manquant sur l''escrow');
  END IF;
  v_commission    := COALESCE(NULLIF(v_escrow.commission_amount, 0), v_escrow.amount * 0.025);
  v_vendor_amount := v_escrow.amount - v_commission;

  -- Crédit vendeur (net) converti
  v_seller_res := public.credit_user_wallet_safe(v_seller, v_vendor_amount, v_cur);
  v_wallet_id  := (v_seller_res->>'wallet_id')::bigint;

  -- Crédit commission PDG converti + LIGNE D'HISTORIQUE (visibilité)
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    v_pdg_res := public.credit_user_wallet_safe(v_pdg, v_commission, v_cur);
    INSERT INTO public.wallet_transactions (
      transaction_id, sender_user_id, receiver_user_id, amount, net_amount, currency,
      transaction_type, status, description, metadata)
    VALUES (
      generate_transaction_id(), NULL, v_pdg, v_commission, v_commission, v_cur,
      'commission', 'completed', 'Commission vendeur (libération escrow)',
      jsonb_build_object('escrow_id', p_escrow_id, 'order_id', v_escrow.order_id,
        'credited', (v_pdg_res->>'credited')::numeric, 'credited_currency', v_pdg_res->>'currency',
        'source', 'escrow_release_commission', 'original_currency', v_cur));
  END IF;

  UPDATE public.escrow_transactions
  SET status = 'released', released_at = now(), commission_amount = v_commission, updated_at = now()
  WHERE id = p_escrow_id;

  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_wallet_id, receiver_user_id, amount, fee, net_amount, currency,
    transaction_type, status, description, metadata)
  VALUES (
    generate_transaction_id(), v_wallet_id, v_seller, v_escrow.amount, v_commission, v_vendor_amount, v_cur,
    'escrow_release', 'completed', 'Fonds escrow libérés',
    jsonb_build_object('escrow_id', p_escrow_id, 'order_id', v_escrow.order_id, 'commission', v_commission,
      'credited', (v_seller_res->>'credited')::numeric, 'credited_currency', v_seller_res->>'currency',
      'reason', p_reason, 'original_currency', v_cur));

  RETURN jsonb_build_object('success', true, 'escrow_id', p_escrow_id, 'vendor_amount', v_vendor_amount,
    'credited', (v_seller_res->>'credited')::numeric, 'credited_currency', v_seller_res->>'currency',
    'commission_amount', v_commission);
END;
$$;

-- ───────────── escrow_monitor_report (+ contrôle escrow_amount_mismatch) ─────────────
CREATE OR REPLACE FUNCTION public.escrow_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_non_converted   int;
  v_net_mismatch    int;
  v_cur_mismatch    int;
  v_no_ledger       int;
  v_held_overdue    int;
  v_stale_rates     int;
  v_rapid           int;
  v_escrow_mismatch int;
BEGIN
  SELECT count(*) INTO v_non_converted FROM public.wallet_transactions
  WHERE transaction_type = 'payment' AND description LIKE 'Libération escrow%'
    AND created_at > now() - interval '7 days';

  SELECT count(*) INTO v_net_mismatch FROM public.wallet_transactions
  WHERE COALESCE(net_amount, 0) <> COALESCE(amount, 0) - COALESCE(fee, 0)
    AND created_at > now() - interval '7 days';

  SELECT count(*) INTO v_cur_mismatch FROM public.wallet_transactions wt
  JOIN public.escrow_transactions e ON e.id::text = wt.metadata->>'escrow_id'
  WHERE wt.transaction_type = 'escrow_release'
    AND wt.currency <> COALESCE(e.currency, 'GNF')
    AND wt.created_at > now() - interval '7 days';

  SELECT count(*) INTO v_no_ledger FROM public.escrow_transactions e
  WHERE e.status = 'released' AND e.released_at > now() - interval '7 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions wt
      WHERE wt.transaction_type = 'escrow_release'
        AND (wt.reference_id = e.id::text OR wt.metadata->>'escrow_id' = e.id::text));

  SELECT count(*) INTO v_held_overdue FROM public.escrow_transactions
  WHERE status = 'held' AND auto_release_at IS NOT NULL
    AND auto_release_at < now() - interval '14 days';

  SELECT count(*) INTO v_stale_rates FROM public.currency_exchange_rates
  WHERE is_active = true AND (from_currency = 'GNF' OR to_currency = 'GNF')
    AND COALESCE(retrieved_at, timestamptz '2000-01-01') < now() - interval '24 hours';

  SELECT count(*) INTO v_rapid FROM public.wallet_transactions
  WHERE transaction_type IN ('escrow_release', 'refund')
    AND created_at > now() - interval '5 minutes';

  -- NOUVEAU : escrow dont le montant dépasse le subtotal produit de la commande (commission acheteur
  -- glissée dans l'escrow → vendeur sur-payé = fuite). 0 = sain.
  SELECT count(*) INTO v_escrow_mismatch FROM public.escrow_transactions e
  JOIN public.orders o ON o.id = e.order_id
  WHERE o.subtotal IS NOT NULL AND e.amount > o.subtotal + 0.01
    AND e.created_at > now() - interval '30 days';

  RETURN jsonb_build_object(
    'generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','non_converted_releases','label','Libérations non converties (Edge cassée)','severity','critical','count',v_non_converted,'observed',v_non_converted),
      jsonb_build_object('key','net_mismatch','label','Incohérence net ≠ montant − frais','severity','critical','count',v_net_mismatch,'observed',v_net_mismatch),
      jsonb_build_object('key','currency_mismatch','label','Devise de libération ≠ devise escrow','severity','high','count',v_cur_mismatch,'observed',v_cur_mismatch),
      jsonb_build_object('key','released_no_ledger','label','Escrow libéré sans trace d''historique','severity','high','count',v_no_ledger,'observed',v_no_ledger),
      jsonb_build_object('key','held_overdue','label','Escrow bloqué > 14j (cron en panne ?)','severity','medium','count',v_held_overdue,'observed',v_held_overdue),
      jsonb_build_object('key','stale_rates','label','Taux BCRG périmés > 24h (conversion à risque)','severity','high','count',v_stale_rates,'observed',v_stale_rates),
      jsonb_build_object('key','rapid_ops','label','Opérations escrow rapides (5 min) — possible attaque','severity',CASE WHEN v_rapid > 30 THEN 'high' ELSE 'low' END,'count',CASE WHEN v_rapid > 30 THEN v_rapid ELSE 0 END,'observed',v_rapid),
      jsonb_build_object('key','escrow_amount_mismatch','label','Escrow > montant produit (commission acheteur incluse → fuite)','severity','critical','count',v_escrow_mismatch,'observed',v_escrow_mismatch)
    )
  );
END;
$$;

SELECT 'release_escrow_to_seller loggue la commission PDG + escrow_monitor_report détecte la fuite escrow.' AS status;
