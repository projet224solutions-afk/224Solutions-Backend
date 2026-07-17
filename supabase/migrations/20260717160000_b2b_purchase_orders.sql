-- ============================================================================
-- 🛒 APPROVISIONNEMENT 224 — Bloc 2 : COMMANDE B2B (un objet, deux chemins)
-- ----------------------------------------------------------------------------
-- Une commande B2B = UN couple lié (orders côté FOURNISSEUR ↔ stock_purchases
-- côté ACHETEUR), synchronisé par des RPC atomiques service_role à CHAQUE
-- transition. Cycle acheteur (stock_purchases.status, CHECK élargi sans toucher
-- au flux manuel draft→document_generated→validated) :
--   ordered → (adjusted → ordered)* → confirmed → shipped
--           → received_partial* → received | cancelled | rejected
-- Cycle fournisseur (enum order_status EXISTANT, aucun nouvel enum) :
--   pending → confirmed → in_transit → delivered → completed | cancelled
--
-- STOCKS MIROIR :
--   confirmation  : stock_quantity -= qty ; reserved_quantity += qty
--                   (les unités réservées ne sont plus vendables par AUCUN chemin
--                   existant — marketplace/POS lisent stock_quantity ; le physique
--                   = stock_quantity + reserved_quantity, affiché « X réservés »)
--   expédition    : reserved_quantity -= qty (sortie définitive de l'entrepôt,
--                   journalisée 'sale' sur le compartiment réservé)
--   annulation    : stock_quantity += qty ; reserved_quantity -= qty (libération)
--   réception     : le stock ACHETEUR monte à la réception validée (Bloc 3).
-- Le journal inventory_history est alimenté automatiquement par le miroir
-- inventory (trigger inventory_movement_trigger) pour tout Δ de stock_quantity —
-- les RPC n'insèrent PAS de doublon (seule l'expédition ajoute une entrée
-- explicite, car reserved_quantity n'est pas couvert par le miroir).
--
-- ARGENT (règle PDG en vigueur = modèle « frais acheteur ») :
--   wallet + on_order : débit acheteur (montant produit + frais
--   purchase_fee_percent versés au PDG) + escrow 'held' — mêmes colonnes et
--   primitives que create_order_core. Libération à la réception (Bloc 3) via
--   release_escrow_to_seller. Annulation → refund_order_escrow (le frais
--   acheteur n'est PAS remboursé — modèle standard plateforme).
--   wallet + on_reception : transfert direct à la réception validée (Bloc 3).
--   cash / credit : aucun mouvement wallet ici (dette créée à la réception).
--
-- PIÈGES NEUTRALISÉS :
--   - restore_stock_on_order_cancel : garde order_type='b2b_purchase' (sinon il
--     recréditerait un stock jamais décrémenté à la création).
--   - decrement_stock_on_order_items : les commandes B2B sont source='online'
--     → le trigger ne décrémente pas à l'insertion des lignes.
--   - is_locked=true dès la création côté achat B2B → RLS UPDATE/DELETE frontend
--     fermées, seules les RPC service_role écrivent.
-- ============================================================================

-- 1) ── orders.order_type (TEXT + CHECK — pas de nouvel enum) ────────────────
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS order_type text NOT NULL DEFAULT 'standard';
DO $$ BEGIN
  ALTER TABLE public.orders ADD CONSTRAINT orders_order_type_chk
    CHECK (order_type IN ('standard','b2b_purchase'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_orders_b2b ON public.orders (vendor_id, created_at DESC)
  WHERE order_type = 'b2b_purchase';

-- 2) ── products.reserved_quantity (compartiment réservé B2B) ────────────────
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS reserved_quantity integer NOT NULL DEFAULT 0;
DO $$ BEGIN
  ALTER TABLE public.products ADD CONSTRAINT products_reserved_quantity_chk
    CHECK (reserved_quantity >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 3) ── stock_purchases : statuts élargis + colonnes B2B ─────────────────────
ALTER TABLE public.stock_purchases DROP CONSTRAINT IF EXISTS stock_purchases_status_check;
ALTER TABLE public.stock_purchases ADD CONSTRAINT stock_purchases_status_check
  CHECK (status IN ('draft','document_generated','validated',
                    'ordered','adjusted','confirmed','shipped',
                    'received_partial','received','cancelled','rejected'));

ALTER TABLE public.stock_purchases DROP CONSTRAINT IF EXISTS stock_purchases_payment_mode_chk;
ALTER TABLE public.stock_purchases ADD CONSTRAINT stock_purchases_payment_mode_chk
  CHECK (payment_mode IN ('cash','credit','wallet'));

ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS linked_order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL;
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS payment_timing text;
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS currency text NOT NULL DEFAULT 'GNF';
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS b2b_buyer_fee numeric NOT NULL DEFAULT 0;
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS confirmed_at timestamptz;
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS shipped_at timestamptz;
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS received_at timestamptz;
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS cancelled_at timestamptz;
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS cancel_reason text;
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS adjustment_note text;
DO $$ BEGIN
  ALTER TABLE public.stock_purchases ADD CONSTRAINT stock_purchases_payment_timing_chk
    CHECK (payment_timing IS NULL OR payment_timing IN ('on_order','on_reception'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE UNIQUE INDEX IF NOT EXISTS ux_stock_purchases_linked_order
  ON public.stock_purchases (linked_order_id) WHERE linked_order_id IS NOT NULL;

-- FK manquante depuis 20260619100000 (supplier_id posé sans REFERENCES) :
-- nécessaire à l'intégrité ET aux jointures PostgREST. NOT VALID puis VALIDATE
-- tolérant (une valeur orpheline historique ne bloque pas la migration).
DO $$ BEGIN
  ALTER TABLE public.stock_purchases
    ADD CONSTRAINT stock_purchases_supplier_fk
    FOREIGN KEY (supplier_id) REFERENCES public.vendor_suppliers(id)
    ON DELETE SET NULL NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE public.stock_purchases VALIDATE CONSTRAINT stock_purchases_supplier_fk;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'stock_purchases_supplier_fk laissée NOT VALID (valeurs orphelines à nettoyer) : %', SQLERRM;
END $$;

-- 4) ── stock_purchase_items : réception + produit fournisseur + ajustements ─
ALTER TABLE public.stock_purchase_items ADD COLUMN IF NOT EXISTS received_quantity integer NOT NULL DEFAULT 0;
ALTER TABLE public.stock_purchase_items ADD COLUMN IF NOT EXISTS supplier_product_id uuid REFERENCES public.products(id) ON DELETE SET NULL;
ALTER TABLE public.stock_purchase_items ADD COLUMN IF NOT EXISTS proposed_quantity integer;
ALTER TABLE public.stock_purchase_items ADD COLUMN IF NOT EXISTS proposed_price numeric;
DO $$ BEGIN
  ALTER TABLE public.stock_purchase_items ADD CONSTRAINT stock_purchase_items_received_chk
    CHECK (received_quantity >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 5) ── Garde B2B sur la restauration de stock à l'annulation ────────────────
-- (identique à 20260604000000, + le garde : les RPC B2B gèrent leur propre stock)
CREATE OR REPLACE FUNCTION public.restore_stock_on_order_cancel()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Commandes B2B : le stock n'est PAS décrémenté à la création (réservation à la
  -- confirmation, gérée par cancel_b2b_order) → ne rien restaurer ici.
  IF COALESCE(NEW.order_type, 'standard') = 'b2b_purchase' THEN
    RETURN NEW;
  END IF;
  IF NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled' THEN
    UPDATE public.products p
    SET stock_quantity = COALESCE(p.stock_quantity, 0) + oi.qty,
        updated_at = NOW()
    FROM (
      SELECT product_id, SUM(quantity) AS qty
      FROM public.order_items
      WHERE order_id = NEW.id
      GROUP BY product_id
    ) oi
    WHERE p.id = oi.product_id;
  END IF;
  RETURN NEW;
END;
$$;

-- 6) ── RPC : créer la commande B2B (envoi) ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_b2b_purchase_order(
  p_buyer_vendor_id uuid, p_supplier_row_id uuid, p_items jsonb,
  p_payment_mode text, p_payment_timing text,
  p_customer_id uuid,
  p_notes text DEFAULT NULL,
  p_wallet_debit_amount numeric DEFAULT 0, p_buyer_wallet_currency text DEFAULT NULL,
  p_buyer_fee_amount numeric DEFAULT 0, p_currency text DEFAULT 'GNF',
  p_due_date date DEFAULT NULL, p_minimum_installment numeric DEFAULT 0
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_supplier record; v_supplier_vendor record; v_buyer record;
  v_item jsonb; v_product record; v_subtotal numeric := 0;
  v_order_id uuid; v_purchase_id uuid; v_order_number text;
  v_lines jsonb := '[]'::jsonb; v_qty int;
  v_buyer_user uuid; v_wallet_cur text; v_total_debit numeric; v_bal numeric;
  v_pdg_user uuid; v_fee_res jsonb; v_release_at timestamptz;
BEGIN
  -- Validations de base
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMPTY_ITEMS');
  END IF;
  IF p_payment_mode NOT IN ('wallet','cash','credit') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PAYMENT_MODE');
  END IF;
  IF p_payment_timing NOT IN ('on_order','on_reception') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PAYMENT_TIMING');
  END IF;
  IF p_payment_mode <> 'wallet' AND p_payment_timing = 'on_order' THEN
    -- cash/credit se règlent hors wallet : le « moment » ne s'applique qu'au wallet.
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_PAYMENT_TIMING');
  END IF;

  -- Fiche fournisseur LIÉE appartenant à l'acheteur
  SELECT * INTO v_supplier FROM public.vendor_suppliers
  WHERE id = p_supplier_row_id AND vendor_id = p_buyer_vendor_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_NOT_FOUND'); END IF;
  IF v_supplier.link_status <> 'linked' OR v_supplier.linked_vendor_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_NOT_LINKED');
  END IF;

  SELECT id, user_id, business_name INTO v_supplier_vendor
  FROM public.vendors WHERE id = v_supplier.linked_vendor_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_VENDOR_GONE'); END IF;

  SELECT id, user_id, business_name INTO v_buyer
  FROM public.vendors WHERE id = p_buyer_vendor_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'BUYER_VENDOR_NOT_FOUND'); END IF;
  v_buyer_user := v_buyer.user_id;

  -- Lignes : produits du fournisseur, prix lus EN BASE (jamais du client),
  -- une ligne par produit, quantité > 0, disponibilité vérifiée (informative —
  -- l'anti-survente ferme est à la CONFIRMATION).
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_qty := COALESCE((v_item->>'quantity')::int, 0);
    IF v_qty <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_QUANTITY');
    END IF;
    SELECT p.id, p.name, p.price, p.stock_quantity INTO v_product
    FROM public.products p
    WHERE p.id = (v_item->>'product_id')::uuid
      AND p.vendor_id = v_supplier.linked_vendor_id AND p.is_active = true
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND',
        'product_id', v_item->>'product_id');
    END IF;
    IF v_lines @> jsonb_build_array(jsonb_build_object('product_id', v_product.id::text)) THEN
      RETURN jsonb_build_object('success', false, 'error', 'DUPLICATE_LINE', 'product_name', v_product.name);
    END IF;
    IF COALESCE(v_product.stock_quantity, 0) < v_qty THEN
      RETURN jsonb_build_object('success', false, 'error', 'STOCK_INSUFFICIENT',
        'product_name', v_product.name, 'available', COALESCE(v_product.stock_quantity, 0));
    END IF;
    v_subtotal := v_subtotal + (COALESCE(v_product.price, 0) * v_qty);
    v_lines := v_lines || jsonb_build_object(
      'product_id', v_product.id::text, 'product_name', v_product.name,
      'quantity', v_qty, 'unit_price', COALESCE(v_product.price, 0));
  END LOOP;

  -- Commande côté FOURNISSEUR (source='online' → pas de décrément trigger).
  v_order_number := 'B2B-' || to_char(now(), 'YYMMDD') || '-' ||
                    upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  INSERT INTO public.orders (order_number, customer_id, vendor_id, status, payment_status,
    payment_method, subtotal, total_amount, shipping_address, currency, source, order_type, metadata)
  VALUES (v_order_number, p_customer_id, v_supplier.linked_vendor_id, 'pending'::order_status,
    CASE WHEN p_payment_mode = 'wallet' AND p_payment_timing = 'on_order'
         THEN 'paid'::payment_status ELSE 'pending'::payment_status END,
    CASE WHEN p_payment_mode = 'wallet' THEN 'wallet'::payment_method ELSE 'cash'::payment_method END,
    v_subtotal, v_subtotal, '{}'::jsonb, p_currency, 'online'::order_source, 'b2b_purchase',
    jsonb_build_object('b2b', true, 'buyer_vendor_id', p_buyer_vendor_id,
      'buyer_business_name', v_buyer.business_name,
      'payment_mode', p_payment_mode, 'payment_timing', p_payment_timing))
  RETURNING id INTO v_order_id;

  INSERT INTO public.order_items (order_id, product_id, product_name, quantity, unit_price, total_price)
  SELECT v_order_id, (l->>'product_id')::uuid, l->>'product_name', (l->>'quantity')::int,
         (l->>'unit_price')::numeric, (l->>'unit_price')::numeric * (l->>'quantity')::int
  FROM jsonb_array_elements(v_lines) AS l;

  -- Achat miroir côté ACHETEUR (verrouillé : seules les RPC écrivent).
  INSERT INTO public.stock_purchases (vendor_id, purchase_number, status, notes, supplier_id,
    payment_mode, payment_timing, currency, due_date, minimum_installment,
    linked_order_id, b2b_buyer_fee, is_locked)
  VALUES (p_buyer_vendor_id, v_order_number, 'ordered', p_notes, p_supplier_row_id,
    p_payment_mode, p_payment_timing, p_currency, p_due_date, COALESCE(p_minimum_installment, 0),
    v_order_id, COALESCE(p_buyer_fee_amount, 0), true)
  RETURNING id INTO v_purchase_id;

  -- selling_price provisoire = prix d'achat (l'acheteur fixe son prix de vente à
  -- la réception ; la colonne est NOT NULL).
  INSERT INTO public.stock_purchase_items (purchase_id, supplier_id, supplier_product_id,
    product_name, quantity, purchase_price, selling_price)
  SELECT v_purchase_id, p_supplier_row_id, (l->>'product_id')::uuid, l->>'product_name',
         (l->>'quantity')::int, (l->>'unit_price')::numeric, (l->>'unit_price')::numeric
  FROM jsonb_array_elements(v_lines) AS l;

  UPDATE public.orders SET metadata = metadata || jsonb_build_object('purchase_id', v_purchase_id)
  WHERE id = v_order_id;

  -- Paiement wallet à la commande : débit + frais acheteur (PDG) + escrow 'held'
  -- (mêmes colonnes/primitives que create_order_core ; libéré à la réception).
  IF p_payment_mode = 'wallet' AND p_payment_timing = 'on_order' THEN
    v_wallet_cur := COALESCE(p_buyer_wallet_currency, p_currency);
    v_total_debit := COALESCE(p_wallet_debit_amount, 0) + COALESCE(p_buyer_fee_amount, 0);
    IF COALESCE(p_wallet_debit_amount, 0) <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_WALLET_AMOUNT');
    END IF;

    SELECT balance INTO v_bal FROM public.wallets
    WHERE user_id = v_buyer_user AND currency = v_wallet_cur FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'WALLET_NOT_FOUND', 'currency', v_wallet_cur);
    END IF;
    IF v_bal < v_total_debit THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_FUNDS',
        'balance', v_bal, 'required', v_total_debit);
    END IF;

    UPDATE public.wallets SET balance = balance - v_total_debit, updated_at = now()
    WHERE user_id = v_buyer_user AND currency = v_wallet_cur;

    INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
      transaction_type, amount, net_amount, currency, description, status, metadata)
    VALUES ('b2b-' || left(replace(gen_random_uuid()::text, '-', ''), 45), v_buyer_user,
      v_supplier_vendor.user_id, 'payment', p_wallet_debit_amount, p_wallet_debit_amount,
      v_wallet_cur, 'Paiement commande fournisseur B2B — fonds bloqués en escrow', 'completed',
      jsonb_build_object('order_id', v_order_id, 'purchase_id', v_purchase_id,
        'order_currency', p_currency, 'wallet_currency', v_wallet_cur,
        'product_amount', v_subtotal, 'total_debited', v_total_debit,
        'buyer_fee_amount', COALESCE(p_buyer_fee_amount, 0), 'source', 'create_b2b_purchase_order'));

    v_release_at := now() + interval '30 days'; -- filet de sécurité ; libération normale = réception
    INSERT INTO public.escrow_transactions (
      order_id, buyer_id, seller_id, payer_id, receiver_id, amount, currency, status,
      auto_release_at, auto_release_date, payment_method, original_amount, original_currency,
      buyer_debit_amount, buyer_debit_currency, exchange_rate_used, is_cross_currency, commission_amount)
    VALUES (v_order_id, v_buyer_user, v_supplier_vendor.user_id, v_buyer_user,
      v_supplier_vendor.user_id, v_subtotal, p_currency, 'held', v_release_at, v_release_at,
      'wallet', v_subtotal, p_currency, p_wallet_debit_amount, v_wallet_cur, NULL,
      (upper(v_wallet_cur) <> upper(p_currency)), 0);

    IF COALESCE(p_buyer_fee_amount, 0) > 0 THEN
      BEGIN
        SELECT user_id INTO v_pdg_user FROM public.pdg_management WHERE is_active = true LIMIT 1;
        IF v_pdg_user IS NOT NULL THEN
          v_fee_res := public.credit_user_wallet_safe(v_pdg_user, p_buyer_fee_amount, v_wallet_cur);
          INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
            transaction_type, amount, net_amount, currency, description, status, metadata)
          VALUES ('fee-' || left(replace(gen_random_uuid()::text, '-', ''), 45), v_buyer_user,
            v_pdg_user, 'commission', p_buyer_fee_amount, p_buyer_fee_amount, v_wallet_cur,
            'Commission acheteur B2B', 'completed',
            jsonb_build_object('order_id', v_order_id, 'purchase_id', v_purchase_id,
              'wallet_currency', v_wallet_cur,
              'pdg_credited', (v_fee_res->>'credited')::numeric, 'pdg_currency', v_fee_res->>'currency',
              'source', 'b2b_buyer_commission'));
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL; -- la commission ne bloque jamais la commande
      END;
    END IF;
  END IF;

  RETURN jsonb_build_object('success', true, 'order_id', v_order_id, 'purchase_id', v_purchase_id,
    'order_number', v_order_number, 'subtotal', v_subtotal, 'currency', p_currency,
    'supplier_user_id', v_supplier_vendor.user_id,
    'supplier_business_name', v_supplier_vendor.business_name,
    'buyer_user_id', v_buyer_user, 'buyer_business_name', v_buyer.business_name,
    'escrow_status', CASE WHEN p_payment_mode = 'wallet' AND p_payment_timing = 'on_order'
                          THEN 'held' ELSE 'none' END);
END;
$$;
REVOKE ALL ON FUNCTION public.create_b2b_purchase_order(uuid, uuid, jsonb, text, text, uuid, text, numeric, text, numeric, text, date, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_b2b_purchase_order(uuid, uuid, jsonb, text, text, uuid, text, numeric, text, numeric, text, date, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_b2b_purchase_order(uuid, uuid, jsonb, text, text, uuid, text, numeric, text, numeric, text, date, numeric) TO service_role;

-- 7) ── Réservation interne (partagée confirm/revalidate) ────────────────────
-- stock_quantity -= qty ; reserved_quantity += qty, par ligne, avec anti-survente.
-- Renvoie NULL si OK, sinon le jsonb d'erreur à retourner tel quel.
CREATE OR REPLACE FUNCTION public.b2b_reserve_order_stock(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_line record; v_stock int;
BEGIN
  FOR v_line IN
    SELECT oi.product_id, oi.product_name, SUM(oi.quantity)::int AS qty
    FROM public.order_items oi WHERE oi.order_id = p_order_id
    GROUP BY oi.product_id, oi.product_name
  LOOP
    SELECT stock_quantity INTO v_stock FROM public.products
    WHERE id = v_line.product_id FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_GONE', 'product_name', v_line.product_name);
    END IF;
    IF COALESCE(v_stock, 0) < v_line.qty THEN
      RETURN jsonb_build_object('success', false, 'error', 'STOCK_INSUFFICIENT',
        'product_name', v_line.product_name, 'available', COALESCE(v_stock, 0), 'requested', v_line.qty);
    END IF;
    UPDATE public.products
    SET stock_quantity = stock_quantity - v_line.qty,
        reserved_quantity = reserved_quantity + v_line.qty,
        updated_at = now()
    WHERE id = v_line.product_id;
  END LOOP;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.b2b_reserve_order_stock(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.b2b_reserve_order_stock(uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.b2b_reserve_order_stock(uuid) TO service_role;

-- 8) ── RPC : confirmer (fournisseur) — avec ou sans ajustements ─────────────
CREATE OR REPLACE FUNCTION public.confirm_b2b_order(
  p_order_id uuid, p_supplier_vendor_id uuid,
  p_adjustments jsonb DEFAULT NULL, p_note text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_order record; v_purchase record; v_adj jsonb; v_err jsonb;
  v_item record; v_count int := 0; v_buyer record;
BEGIN
  SELECT * INTO v_order FROM public.orders
  WHERE id = p_order_id AND vendor_id = p_supplier_vendor_id
    AND order_type = 'b2b_purchase' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND'); END IF;
  IF v_order.status <> 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_order.status::text);
  END IF;

  SELECT * INTO v_purchase FROM public.stock_purchases
  WHERE linked_order_id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_GONE'); END IF;
  IF v_purchase.status NOT IN ('ordered','adjusted') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_purchase.status);
  END IF;

  SELECT v.user_id, v.business_name INTO v_buyer FROM public.vendors v WHERE v.id = v_purchase.vendor_id;

  IF p_adjustments IS NOT NULL AND jsonb_array_length(p_adjustments) > 0 THEN
    -- AJUSTEMENT ligne à ligne (dispo/prix) → l'acheteur devra REVALIDER.
    FOR v_adj IN SELECT * FROM jsonb_array_elements(p_adjustments) LOOP
      UPDATE public.stock_purchase_items
      SET proposed_quantity = GREATEST(COALESCE((v_adj->>'quantity')::int, quantity), 0),
          proposed_price    = GREATEST(COALESCE(NULLIF(v_adj->>'unit_price','')::numeric, purchase_price), 0)
      WHERE purchase_id = v_purchase.id
        AND supplier_product_id = (v_adj->>'product_id')::uuid;
      GET DIAGNOSTICS v_count = ROW_COUNT;
      IF v_count = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'LINE_NOT_FOUND',
          'product_id', v_adj->>'product_id');
      END IF;
    END LOOP;
    -- Aucun changement réel ? (toutes les propositions = valeurs actuelles)
    SELECT count(*) INTO v_count FROM public.stock_purchase_items
    WHERE purchase_id = v_purchase.id
      AND (proposed_quantity IS DISTINCT FROM quantity
           OR proposed_price IS DISTINCT FROM purchase_price)
      AND (proposed_quantity IS NOT NULL OR proposed_price IS NOT NULL);
    IF v_count = 0 THEN
      -- Pas de vrai changement → confirmation directe (nettoie les propositions).
      UPDATE public.stock_purchase_items
      SET proposed_quantity = NULL, proposed_price = NULL
      WHERE purchase_id = v_purchase.id;
    ELSE
      UPDATE public.stock_purchases
      SET status = 'adjusted', adjustment_note = NULLIF(trim(COALESCE(p_note,'')), '')
      WHERE id = v_purchase.id;
      RETURN jsonb_build_object('success', true, 'adjusted', true,
        'purchase_id', v_purchase.id, 'order_number', v_order.order_number,
        'buyer_user_id', v_buyer.user_id, 'buyer_business_name', v_buyer.business_name);
    END IF;
  END IF;

  -- CONFIRMATION ferme : réservation miroir (anti-survente).
  v_err := public.b2b_reserve_order_stock(p_order_id);
  IF v_err IS NOT NULL THEN RETURN v_err; END IF;

  UPDATE public.orders SET status = 'confirmed'::order_status, updated_at = now()
  WHERE id = p_order_id;
  UPDATE public.stock_purchases SET status = 'confirmed', confirmed_at = now()
  WHERE id = v_purchase.id;

  RETURN jsonb_build_object('success', true, 'adjusted', false,
    'purchase_id', v_purchase.id, 'order_number', v_order.order_number,
    'buyer_user_id', v_buyer.user_id, 'buyer_business_name', v_buyer.business_name);
END;
$$;
REVOKE ALL ON FUNCTION public.confirm_b2b_order(uuid, uuid, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.confirm_b2b_order(uuid, uuid, jsonb, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_b2b_order(uuid, uuid, jsonb, text) TO service_role;

-- 9) ── RPC : revalidation acheteur après ajustement ─────────────────────────
CREATE OR REPLACE FUNCTION public.revalidate_b2b_order(
  p_order_id uuid, p_buyer_vendor_id uuid, p_accept boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_order record; v_purchase record; v_line record; v_err jsonb;
  v_new_subtotal numeric := 0; v_old_subtotal numeric;
  v_escrow record; v_rate numeric; v_delta numeric; v_fee_pct numeric; v_fee_delta numeric := 0;
  v_bal numeric; v_buyer_user uuid; v_pdg_user uuid; v_fee_res jsonb;
  v_supplier record; v_no_dec boolean;
BEGIN
  SELECT * INTO v_purchase FROM public.stock_purchases
  WHERE linked_order_id = p_order_id AND vendor_id = p_buyer_vendor_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FOUND'); END IF;
  IF v_purchase.status <> 'adjusted' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_purchase.status);
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'ORDER_GONE'); END IF;

  SELECT v.user_id, v.business_name INTO v_supplier FROM public.vendors v WHERE v.id = v_order.vendor_id;
  SELECT v.user_id INTO v_buyer_user FROM public.vendors v WHERE v.id = p_buyer_vendor_id;

  IF NOT p_accept THEN
    -- Refus des ajustements = annulation propre (rien n'était réservé).
    PERFORM public.refund_order_escrow(p_order_id);
    UPDATE public.orders SET status = 'cancelled'::order_status, updated_at = now() WHERE id = p_order_id;
    UPDATE public.stock_purchases
    SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'adjustment_refused'
    WHERE id = v_purchase.id;
    RETURN jsonb_build_object('success', true, 'accepted', false, 'cancelled', true,
      'order_number', v_order.order_number,
      'supplier_user_id', v_supplier.user_id, 'supplier_business_name', v_supplier.business_name);
  END IF;

  -- 1) Appliquer les propositions aux lignes miroir (quantité 0 = ligne retirée).
  DELETE FROM public.stock_purchase_items
  WHERE purchase_id = v_purchase.id AND proposed_quantity = 0;
  UPDATE public.stock_purchase_items
  SET quantity = COALESCE(proposed_quantity, quantity),
      purchase_price = COALESCE(proposed_price, purchase_price),
      selling_price = GREATEST(selling_price, COALESCE(proposed_price, purchase_price)),
      proposed_quantity = NULL, proposed_price = NULL
  WHERE purchase_id = v_purchase.id;

  IF NOT EXISTS (SELECT 1 FROM public.stock_purchase_items WHERE purchase_id = v_purchase.id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'ALL_LINES_REMOVED');
  END IF;

  -- 2) Resynchroniser les lignes de la commande fournisseur.
  DELETE FROM public.order_items WHERE order_id = p_order_id;
  INSERT INTO public.order_items (order_id, product_id, product_name, quantity, unit_price, total_price)
  SELECT p_order_id, spi.supplier_product_id, spi.product_name, spi.quantity,
         spi.purchase_price, spi.purchase_price * spi.quantity
  FROM public.stock_purchase_items spi WHERE spi.purchase_id = v_purchase.id;

  SELECT COALESCE(SUM(total_price), 0) INTO v_new_subtotal FROM public.order_items WHERE order_id = p_order_id;
  v_old_subtotal := COALESCE(v_order.subtotal, 0);

  -- 3) Paiement wallet à la commande : delta escrow (remboursement partiel ou
  --    complément débité). Le frais acheteur initial n'est pas remboursé (modèle
  --    standard) ; un complément de frais s'applique sur le delta à la hausse.
  IF v_purchase.payment_mode = 'wallet' AND v_purchase.payment_timing = 'on_order'
     AND v_new_subtotal <> v_old_subtotal THEN
    SELECT * INTO v_escrow FROM public.escrow_transactions
    WHERE order_id = p_order_id AND status = 'held' FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'ESCROW_GONE'); END IF;

    v_rate := CASE WHEN v_old_subtotal > 0
                   THEN COALESCE(v_escrow.buyer_debit_amount, v_old_subtotal) / v_old_subtotal
                   ELSE 1 END;
    v_no_dec := upper(COALESCE(v_escrow.buyer_debit_currency, 'GNF'))
                IN ('GNF','XOF','XAF','JPY','KRW','VND','CLP');

    IF v_new_subtotal < v_old_subtotal THEN
      v_delta := (v_old_subtotal - v_new_subtotal) * v_rate;
      v_delta := CASE WHEN v_no_dec THEN round(v_delta) ELSE round(v_delta, 2) END;
      IF v_delta > 0 THEN
        UPDATE public.wallets SET balance = balance + v_delta, updated_at = now()
        WHERE user_id = v_buyer_user AND currency = COALESCE(v_escrow.buyer_debit_currency, 'GNF');
        IF NOT FOUND THEN
          RETURN jsonb_build_object('success', false, 'error', 'BUYER_WALLET_GONE');
        END IF;
        INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
          transaction_type, amount, net_amount, currency, description, status, metadata)
        VALUES ('b2ba-' || left(replace(gen_random_uuid()::text, '-', ''), 44), NULL, v_buyer_user,
          'refund', v_delta, v_delta, COALESCE(v_escrow.buyer_debit_currency, 'GNF'),
          'Ajustement commande B2B — remboursement partiel', 'completed',
          jsonb_build_object('order_id', p_order_id, 'purchase_id', v_purchase.id,
            'old_subtotal', v_old_subtotal, 'new_subtotal', v_new_subtotal, 'source', 'revalidate_b2b_order'));
      END IF;
      UPDATE public.escrow_transactions
      SET amount = v_new_subtotal, original_amount = v_new_subtotal,
          buyer_debit_amount = GREATEST(COALESCE(buyer_debit_amount, 0) - v_delta, 0), updated_at = now()
      WHERE id = v_escrow.id;
    ELSE
      v_delta := (v_new_subtotal - v_old_subtotal) * v_rate;
      v_delta := CASE WHEN v_no_dec THEN round(v_delta) ELSE round(v_delta, 2) END;
      v_fee_pct := COALESCE(public.get_purchase_commission_percent(), 0);
      v_fee_delta := v_delta * v_fee_pct / 100.0;
      v_fee_delta := CASE WHEN v_no_dec THEN round(v_fee_delta) ELSE round(v_fee_delta, 2) END;

      SELECT balance INTO v_bal FROM public.wallets
      WHERE user_id = v_buyer_user AND currency = COALESCE(v_escrow.buyer_debit_currency, 'GNF') FOR UPDATE;
      IF NOT FOUND OR v_bal < (v_delta + v_fee_delta) THEN
        RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_FUNDS',
          'required', v_delta + v_fee_delta, 'balance', COALESCE(v_bal, 0));
      END IF;
      UPDATE public.wallets SET balance = balance - (v_delta + v_fee_delta), updated_at = now()
      WHERE user_id = v_buyer_user AND currency = COALESCE(v_escrow.buyer_debit_currency, 'GNF');
      INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
        transaction_type, amount, net_amount, currency, description, status, metadata)
      VALUES ('b2ba-' || left(replace(gen_random_uuid()::text, '-', ''), 44), v_buyer_user,
        v_supplier.user_id, 'payment', v_delta, v_delta,
        COALESCE(v_escrow.buyer_debit_currency, 'GNF'),
        'Ajustement commande B2B — complément débité', 'completed',
        jsonb_build_object('order_id', p_order_id, 'purchase_id', v_purchase.id,
          'old_subtotal', v_old_subtotal, 'new_subtotal', v_new_subtotal,
          'fee_delta', v_fee_delta, 'source', 'revalidate_b2b_order'));
      UPDATE public.escrow_transactions
      SET amount = v_new_subtotal, original_amount = v_new_subtotal,
          buyer_debit_amount = COALESCE(buyer_debit_amount, 0) + v_delta, updated_at = now()
      WHERE id = v_escrow.id;

      IF v_fee_delta > 0 THEN
        BEGIN
          SELECT user_id INTO v_pdg_user FROM public.pdg_management WHERE is_active = true LIMIT 1;
          IF v_pdg_user IS NOT NULL THEN
            v_fee_res := public.credit_user_wallet_safe(v_pdg_user, v_fee_delta,
              COALESCE(v_escrow.buyer_debit_currency, 'GNF'));
            INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
              transaction_type, amount, net_amount, currency, description, status, metadata)
            VALUES ('fee-' || left(replace(gen_random_uuid()::text, '-', ''), 45), v_buyer_user,
              v_pdg_user, 'commission', v_fee_delta, v_fee_delta,
              COALESCE(v_escrow.buyer_debit_currency, 'GNF'),
              'Commission acheteur B2B (complément ajustement)', 'completed',
              jsonb_build_object('order_id', p_order_id, 'purchase_id', v_purchase.id,
                'source', 'b2b_buyer_commission_adjustment'));
            UPDATE public.stock_purchases SET b2b_buyer_fee = b2b_buyer_fee + v_fee_delta
            WHERE id = v_purchase.id;
          END IF;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
      END IF;
    END IF;
  END IF;

  UPDATE public.orders SET subtotal = v_new_subtotal, total_amount = v_new_subtotal, updated_at = now()
  WHERE id = p_order_id;

  -- 4) Réservation miroir + statuts confirmés.
  v_err := public.b2b_reserve_order_stock(p_order_id);
  IF v_err IS NOT NULL THEN RETURN v_err; END IF;

  UPDATE public.orders SET status = 'confirmed'::order_status, updated_at = now() WHERE id = p_order_id;
  UPDATE public.stock_purchases SET status = 'confirmed', confirmed_at = now() WHERE id = v_purchase.id;

  RETURN jsonb_build_object('success', true, 'accepted', true,
    'order_number', v_order.order_number, 'new_subtotal', v_new_subtotal,
    'supplier_user_id', v_supplier.user_id, 'supplier_business_name', v_supplier.business_name);
END;
$$;
REVOKE ALL ON FUNCTION public.revalidate_b2b_order(uuid, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.revalidate_b2b_order(uuid, uuid, boolean) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.revalidate_b2b_order(uuid, uuid, boolean) TO service_role;

-- 10) ── RPC : expédier (fournisseur) ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ship_b2b_order(
  p_order_id uuid, p_supplier_vendor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_order record; v_purchase record; v_line record; v_reserved int; v_buyer record;
BEGIN
  SELECT * INTO v_order FROM public.orders
  WHERE id = p_order_id AND vendor_id = p_supplier_vendor_id
    AND order_type = 'b2b_purchase' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND'); END IF;
  IF v_order.status <> 'confirmed' THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_order.status::text);
  END IF;

  SELECT * INTO v_purchase FROM public.stock_purchases WHERE linked_order_id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_GONE'); END IF;

  -- Sortie DÉFINITIVE du stock réservé (la marchandise quitte l'entrepôt).
  FOR v_line IN
    SELECT oi.product_id, oi.product_name, SUM(oi.quantity)::int AS qty
    FROM public.order_items oi WHERE oi.order_id = p_order_id
    GROUP BY oi.product_id, oi.product_name
  LOOP
    SELECT reserved_quantity INTO v_reserved FROM public.products
    WHERE id = v_line.product_id FOR UPDATE;
    IF NOT FOUND OR COALESCE(v_reserved, 0) < v_line.qty THEN
      RETURN jsonb_build_object('success', false, 'error', 'RESERVATION_INTEGRITY',
        'product_name', v_line.product_name, 'reserved', COALESCE(v_reserved, 0), 'expected', v_line.qty);
    END IF;
    UPDATE public.products
    SET reserved_quantity = reserved_quantity - v_line.qty, updated_at = now()
    WHERE id = v_line.product_id;
    -- Journal explicite : le miroir inventory ne couvre pas reserved_quantity.
    -- previous/new = compartiment RÉSERVÉ (précisé dans notes).
    INSERT INTO public.inventory_history (product_id, vendor_id, movement_type, quantity_change,
      previous_quantity, new_quantity, order_id, notes)
    VALUES (v_line.product_id, p_supplier_vendor_id, 'sale', -v_line.qty,
      v_reserved, v_reserved - v_line.qty, p_order_id,
      'Expédition B2B ' || v_order.order_number || ' — sortie du stock réservé (compteurs = réservé)');
  END LOOP;

  UPDATE public.orders SET status = 'in_transit'::order_status, updated_at = now() WHERE id = p_order_id;
  UPDATE public.stock_purchases SET status = 'shipped', shipped_at = now() WHERE id = v_purchase.id;

  SELECT v.user_id, v.business_name INTO v_buyer FROM public.vendors v WHERE v.id = v_purchase.vendor_id;
  RETURN jsonb_build_object('success', true, 'order_number', v_order.order_number,
    'purchase_id', v_purchase.id,
    'buyer_user_id', v_buyer.user_id, 'buyer_business_name', v_buyer.business_name);
END;
$$;
REVOKE ALL ON FUNCTION public.ship_b2b_order(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ship_b2b_order(uuid, uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ship_b2b_order(uuid, uuid) TO service_role;

-- 11) ── RPC : annuler / refuser (avant expédition) ──────────────────────────
CREATE OR REPLACE FUNCTION public.cancel_b2b_order(
  p_order_id uuid, p_caller_vendor_id uuid, p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_order record; v_purchase record; v_line record; v_refund jsonb;
  v_is_supplier boolean; v_is_buyer boolean; v_new_status text;
  v_other record;
BEGIN
  SELECT * INTO v_order FROM public.orders
  WHERE id = p_order_id AND order_type = 'b2b_purchase' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND'); END IF;

  SELECT * INTO v_purchase FROM public.stock_purchases WHERE linked_order_id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_GONE'); END IF;

  v_is_supplier := (v_order.vendor_id = p_caller_vendor_id);
  v_is_buyer := (v_purchase.vendor_id = p_caller_vendor_id);
  IF NOT v_is_supplier AND NOT v_is_buyer THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_A_PARTY');
  END IF;
  IF v_purchase.status NOT IN ('ordered','adjusted','confirmed') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_purchase.status);
  END IF;

  -- Libérer la réservation si la commande était confirmée (jamais de stock fantôme).
  IF v_purchase.status = 'confirmed' THEN
    FOR v_line IN
      SELECT oi.product_id, SUM(oi.quantity)::int AS qty
      FROM public.order_items oi WHERE oi.order_id = p_order_id GROUP BY oi.product_id
    LOOP
      UPDATE public.products
      SET stock_quantity = COALESCE(stock_quantity, 0) + v_line.qty,
          reserved_quantity = GREATEST(reserved_quantity - v_line.qty, 0),
          updated_at = now()
      WHERE id = v_line.product_id;
    END LOOP;
  END IF;

  -- Rembourser l'escrow wallet éventuel (frais acheteur non remboursé — standard).
  v_refund := public.refund_order_escrow(p_order_id);
  IF v_refund IS NOT NULL AND (v_refund->>'success')::boolean IS DISTINCT FROM true THEN
    RETURN jsonb_build_object('success', false, 'error', 'REFUND_FAILED',
      'detail', v_refund->>'error');
  END IF;

  v_new_status := CASE WHEN v_is_supplier AND v_purchase.status IN ('ordered','adjusted')
                       THEN 'rejected' ELSE 'cancelled' END;

  UPDATE public.orders SET status = 'cancelled'::order_status, updated_at = now() WHERE id = p_order_id;
  UPDATE public.stock_purchases
  SET status = v_new_status, cancelled_at = now(),
      cancel_reason = NULLIF(trim(COALESCE(p_reason,'')), '')
  WHERE id = v_purchase.id;

  -- Notifier l'AUTRE partie (données renvoyées au backend).
  IF v_is_supplier THEN
    SELECT v.user_id, v.business_name INTO v_other FROM public.vendors v WHERE v.id = v_purchase.vendor_id;
  ELSE
    SELECT v.user_id, v.business_name INTO v_other FROM public.vendors v WHERE v.id = v_order.vendor_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'new_status', v_new_status,
    'order_number', v_order.order_number, 'purchase_id', v_purchase.id,
    'cancelled_by', CASE WHEN v_is_supplier THEN 'supplier' ELSE 'buyer' END,
    'other_user_id', v_other.user_id, 'other_business_name', v_other.business_name,
    'refunded_amount', COALESCE((v_refund->>'refunded_amount')::numeric, 0));
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_b2b_order(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_b2b_order(uuid, uuid, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_b2b_order(uuid, uuid, text) TO service_role;

-- ── Auto-test : contraintes en place ────────────────────────────────────────
DO $$
BEGIN
  PERFORM 1 FROM information_schema.columns
  WHERE table_schema='public' AND table_name='products' AND column_name='reserved_quantity';
  IF NOT FOUND THEN RAISE EXCEPTION 'products.reserved_quantity manquant'; END IF;
  PERFORM 1 FROM information_schema.columns
  WHERE table_schema='public' AND table_name='orders' AND column_name='order_type';
  IF NOT FOUND THEN RAISE EXCEPTION 'orders.order_type manquant'; END IF;
  RAISE NOTICE 'OK : colonnes B2B en place.';
END $$;

SELECT 'Bloc 2 commande B2B : orders.order_type + statuts + réservation miroir + RPC create/confirm/revalidate/ship/cancel.' AS status;
