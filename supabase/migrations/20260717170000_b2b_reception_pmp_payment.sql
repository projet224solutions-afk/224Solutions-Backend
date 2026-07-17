-- ============================================================================
-- 📦 APPROVISIONNEMENT 224 — Blocs 3+4 : RÉCEPTION (pivot acheteur) + PMP +
--                                        PAIEMENT / DETTES
-- ----------------------------------------------------------------------------
-- RÉCEPTION (commun aux deux chemins) :
--   - B2B : receive_b2b_purchase — partiel autorisé (received_partial, reliquat
--     attendu), mapping ligne → produit acheteur (existant ou créé), entrée de
--     stock + PMP par ligne, écarts tracés (reception_report), finalisation
--     financière au passage à 'received'.
--   - EXTERNE : validate_stock_purchase passe au PMP (même signature — avant :
--     cost_price ÉCRASÉ par le dernier prix d'achat).
--
-- PMP (prix moyen pondéré) — helper commun apply_purchase_to_product_stock :
--   nouveau_coût = (stock_actuel×coût_actuel + qté_reçue×prix_achat)
--                  / (stock_actuel + qté_reçue)
--   (si stock ≤ 0 ou coût NULL/0 → prix d'achat). C'est LA base du profit juste.
--
-- PAIEMENT à la finalisation de la réception (statut 'received') :
--   - wallet + on_order  : remboursement du manquant (écarts) à l'acheteur puis
--     release_escrow_to_seller (le fournisseur reçoit la valeur REÇUE, intégrale
--     — commission fournisseur 0, modèle frais acheteur).
--   - wallet + on_reception : débit acheteur (+ frais PDG) et crédit fournisseur
--     (credit_user_wallet_safe) — transfert direct tracé.
--   - credit : dette supplier_debts sur la valeur REÇUE (échéance/tranche de la
--     commande) + dépense 'pending' — rappels J-3/J/J+1 par le job backend
--     supplier-debts.reminders.
--   - cash : dépense payée (l'acheteur règle hors app).
--   Dans tous les cas : dépense vendor_expenses tracée + fiche fournisseur
--   marquée has_validated_purchases.
--
-- DETTES : pay_supplier_debt (même signature) crédite désormais le WALLET du
-- fournisseur LIÉ (transfert réel) au lieu d'un simple retrait — les fournisseurs
-- externes gardent le comportement actuel (retrait, réglé hors app).
-- ============================================================================

-- 0) ── Colonnes réception ───────────────────────────────────────────────────
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS reception_report jsonb;
CREATE INDEX IF NOT EXISTS idx_supplier_debts_due ON public.supplier_debts (due_date)
  WHERE status IN ('in_progress','overdue');

-- 1) ── Helper PMP : entrée de stock + coût moyen pondéré ────────────────────
CREATE OR REPLACE FUNCTION public.apply_purchase_to_product_stock(
  p_product_id uuid, p_vendor_id uuid, p_qty integer, p_unit_cost numeric
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_old_stock integer; v_old_cost numeric; v_new_stock integer; v_new_cost numeric;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_QTY');
  END IF;

  SELECT COALESCE(stock_quantity, 0), cost_price INTO v_old_stock, v_old_cost
  FROM public.products
  WHERE id = p_product_id AND vendor_id = p_vendor_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_NOT_FOUND');
  END IF;

  -- PMP : (stock×coût + qté×prix_achat) / (stock+qté). Stock nul/négatif ou coût
  -- inconnu → le coût devient le prix d'achat.
  IF v_old_stock <= 0 OR v_old_cost IS NULL OR v_old_cost <= 0 THEN
    v_new_cost := p_unit_cost;
  ELSE
    v_new_cost := round(
      ((v_old_stock::numeric * v_old_cost) + (p_qty::numeric * COALESCE(p_unit_cost, 0)))
      / (v_old_stock + p_qty)::numeric, 2);
  END IF;
  v_new_stock := v_old_stock + p_qty;

  UPDATE public.products
  SET stock_quantity = v_new_stock, cost_price = v_new_cost, updated_at = now()
  WHERE id = p_product_id;

  RETURN jsonb_build_object('success', true,
    'old_stock', v_old_stock, 'new_stock', v_new_stock,
    'old_cost', v_old_cost, 'new_cost', v_new_cost);
END;
$$;
REVOKE ALL ON FUNCTION public.apply_purchase_to_product_stock(uuid, uuid, integer, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.apply_purchase_to_product_stock(uuid, uuid, integer, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_purchase_to_product_stock(uuid, uuid, integer, numeric) TO service_role;

-- 2) ── RPC : réceptionner un achat B2B (partiel/total, atomique) ────────────
CREATE OR REPLACE FUNCTION public.receive_b2b_purchase(
  p_purchase_id uuid, p_buyer_vendor_id uuid, p_lines jsonb,
  p_close boolean DEFAULT false, p_note text DEFAULT NULL,
  p_wallet_debit_amount numeric DEFAULT 0, p_buyer_wallet_currency text DEFAULT NULL,
  p_buyer_fee_amount numeric DEFAULT 0
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_purchase record; v_order record; v_buyer_user uuid; v_supplier_user uuid;
  v_supplier_name text; v_line jsonb; v_item record; v_recv int;
  v_buyer_product uuid; v_np jsonb; v_pmp jsonb;
  v_report jsonb := '[]'::jsonb; v_all_received boolean; v_final boolean;
  v_received_value numeric := 0; v_ordered_value numeric := 0;
  v_escrow record; v_rate numeric; v_shortfall numeric; v_release jsonb;
  v_bal numeric; v_wallet_cur text; v_total_debit numeric;
  v_pdg_user uuid; v_fee_res jsonb; v_debt_id uuid; v_expense_id uuid;
  v_desc text; v_no_dec boolean; v_gap_lines jsonb := '[]'::jsonb;
BEGIN
  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'EMPTY_LINES');
  END IF;

  SELECT * INTO v_purchase FROM public.stock_purchases
  WHERE id = p_purchase_id AND vendor_id = p_buyer_vendor_id
    AND linked_order_id IS NOT NULL
  FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'PURCHASE_NOT_FOUND'); END IF;
  IF v_purchase.status NOT IN ('shipped','received_partial') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_purchase.status);
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = v_purchase.linked_order_id FOR UPDATE;
  SELECT v.user_id INTO v_buyer_user FROM public.vendors v WHERE v.id = p_buyer_vendor_id;
  SELECT v.user_id, v.business_name INTO v_supplier_user, v_supplier_name
  FROM public.vendors v WHERE v.id = v_order.vendor_id;

  -- ── Lignes reçues : mapping produit acheteur + entrée stock + PMP ──
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    SELECT * INTO v_item FROM public.stock_purchase_items
    WHERE id = (v_line->>'item_id')::uuid AND purchase_id = p_purchase_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'LINE_NOT_FOUND', 'item_id', v_line->>'item_id');
    END IF;

    v_recv := COALESCE((v_line->>'received_qty')::int, 0);
    IF v_recv < 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_RECEIVED_QTY');
    END IF;
    IF v_recv > (v_item.quantity - v_item.received_quantity) THEN
      RETURN jsonb_build_object('success', false, 'error', 'RECEIVED_EXCEEDS_ORDERED',
        'product_name', v_item.product_name,
        'remaining', v_item.quantity - v_item.received_quantity, 'received', v_recv);
    END IF;
    IF v_recv = 0 THEN CONTINUE; END IF;

    -- Produit acheteur : fourni, déjà mappé, ou créé automatiquement.
    v_buyer_product := COALESCE(NULLIF(v_line->>'buyer_product_id','')::uuid, v_item.product_id);
    IF v_buyer_product IS NOT NULL THEN
      PERFORM 1 FROM public.products WHERE id = v_buyer_product AND vendor_id = p_buyer_vendor_id;
      IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'BUYER_PRODUCT_INVALID',
          'product_name', v_item.product_name);
      END IF;
    ELSE
      v_np := v_line->'new_product';
      INSERT INTO public.products (vendor_id, name, price, stock_quantity, is_active, category_id)
      VALUES (
        p_buyer_vendor_id,
        COALESCE(NULLIF(v_np->>'name',''), v_item.product_name),
        GREATEST(COALESCE(NULLIF(v_np->>'selling_price','')::numeric, v_item.selling_price,
                          v_item.purchase_price), 0),
        0, true, NULLIF(v_np->>'category_id','')::uuid)
      RETURNING id INTO v_buyer_product;
    END IF;

    -- Entrée de stock + PMP (le journal inventory_history est alimenté par le
    -- miroir inventory — pas d'insertion manuelle ici).
    v_pmp := public.apply_purchase_to_product_stock(
      v_buyer_product, p_buyer_vendor_id, v_recv, v_item.purchase_price);
    IF (v_pmp->>'success')::boolean IS DISTINCT FROM true THEN
      RETURN jsonb_build_object('success', false, 'error', 'STOCK_ENTRY_FAILED',
        'product_name', v_item.product_name, 'detail', v_pmp->>'error');
    END IF;

    UPDATE public.stock_purchase_items
    SET received_quantity = received_quantity + v_recv, product_id = v_buyer_product
    WHERE id = v_item.id;

    v_report := v_report || jsonb_build_object(
      'item_id', v_item.id, 'product_name', v_item.product_name,
      'buyer_product_id', v_buyer_product, 'received_now', v_recv,
      'unit_cost', v_item.purchase_price,
      'old_stock', v_pmp->'old_stock', 'new_stock', v_pmp->'new_stock',
      'old_cost', v_pmp->'old_cost', 'new_cost', v_pmp->'new_cost');
  END LOOP;

  -- ── État global : tout reçu ? écarts ? ──
  SELECT bool_and(received_quantity >= quantity),
         COALESCE(SUM(received_quantity * purchase_price), 0),
         COALESCE(SUM(quantity * purchase_price), 0)
  INTO v_all_received, v_received_value, v_ordered_value
  FROM public.stock_purchase_items WHERE purchase_id = p_purchase_id;

  v_final := v_all_received OR COALESCE(p_close, false);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'item_id', id, 'product_name', product_name,
    'ordered', quantity, 'received', received_quantity,
    'gap', quantity - received_quantity)), '[]'::jsonb)
  INTO v_gap_lines
  FROM public.stock_purchase_items
  WHERE purchase_id = p_purchase_id AND received_quantity < quantity;

  IF NOT v_final THEN
    UPDATE public.stock_purchases
    SET status = 'received_partial',
        reception_report = jsonb_build_object('lines', v_report, 'gaps', v_gap_lines,
          'closed', false, 'note', p_note)
    WHERE id = p_purchase_id;
    RETURN jsonb_build_object('success', true, 'final', false, 'status', 'received_partial',
      'report', v_report, 'gaps', v_gap_lines,
      'supplier_user_id', v_supplier_user, 'supplier_business_name', v_supplier_name,
      'order_number', v_order.order_number);
  END IF;

  -- ══ FINALISATION (statut 'received') ══
  v_desc := 'Achat fournisseur B2B - ' || v_order.order_number || ' - ' || COALESCE(v_supplier_name, '');

  IF v_purchase.payment_mode = 'wallet' AND v_purchase.payment_timing = 'on_order' THEN
    -- Escrow retenu à la commande : rembourser le MANQUANT (écarts) puis libérer.
    SELECT * INTO v_escrow FROM public.escrow_transactions
    WHERE order_id = v_purchase.linked_order_id AND status = 'held' FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'B2B_ESCROW_MISSING for order %', v_purchase.linked_order_id;
    END IF;

    v_shortfall := GREATEST(COALESCE(v_escrow.amount, 0) - v_received_value, 0);
    IF v_shortfall > 0 THEN
      v_rate := CASE WHEN COALESCE(v_escrow.amount, 0) > 0
                     THEN COALESCE(v_escrow.buyer_debit_amount, v_escrow.amount) / v_escrow.amount
                     ELSE 1 END;
      v_no_dec := upper(COALESCE(v_escrow.buyer_debit_currency, 'GNF'))
                  IN ('GNF','XOF','XAF','JPY','KRW','VND','CLP');
      v_shortfall := CASE WHEN v_no_dec THEN round(v_shortfall * v_rate)
                          ELSE round(v_shortfall * v_rate, 2) END;
      IF v_shortfall > 0 THEN
        UPDATE public.wallets SET balance = balance + v_shortfall, updated_at = now()
        WHERE user_id = v_buyer_user AND currency = COALESCE(v_escrow.buyer_debit_currency, 'GNF');
        IF NOT FOUND THEN RAISE EXCEPTION 'B2B_BUYER_WALLET_MISSING'; END IF;
        INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
          transaction_type, amount, net_amount, currency, description, status, metadata)
        VALUES ('b2br-' || left(replace(gen_random_uuid()::text, '-', ''), 44), NULL, v_buyer_user,
          'refund', v_shortfall, v_shortfall, COALESCE(v_escrow.buyer_debit_currency, 'GNF'),
          'Réception B2B — remboursement des écarts', 'completed',
          jsonb_build_object('order_id', v_purchase.linked_order_id, 'purchase_id', p_purchase_id,
            'ordered_value', v_ordered_value, 'received_value', v_received_value,
            'source', 'receive_b2b_purchase'));
        UPDATE public.escrow_transactions
        SET amount = v_received_value, original_amount = v_received_value,
            buyer_debit_amount = GREATEST(COALESCE(buyer_debit_amount, 0) - v_shortfall, 0),
            updated_at = now()
        WHERE id = v_escrow.id;
      END IF;
    END IF;

    -- Libération canonique (fail-closed : échec → toute la réception est annulée).
    v_release := public.release_escrow_to_seller(v_escrow.id, 'b2b_reception_complete');
    IF (v_release->>'success')::boolean IS DISTINCT FROM true
       AND COALESCE((v_release->>'skipped')::boolean, false) IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'B2B_ESCROW_RELEASE_FAILED: %', COALESCE(v_release->>'error', 'inconnu');
    END IF;

    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date,
      payment_method, status, is_locked, purchase_reference)
    VALUES (v_buyer_user, v_desc, v_received_value, CURRENT_DATE, 'wallet', 'paid', true,
      v_order.order_number)
    RETURNING id INTO v_expense_id;

  ELSIF v_purchase.payment_mode = 'wallet' AND v_purchase.payment_timing = 'on_reception' THEN
    -- Transfert direct acheteur → fournisseur (+ frais PDG) au moment pivot.
    v_wallet_cur := COALESCE(p_buyer_wallet_currency, v_purchase.currency, 'GNF');
    IF upper(v_wallet_cur) = upper(COALESCE(v_purchase.currency, 'GNF'))
       AND COALESCE(p_wallet_debit_amount, 0) <> v_received_value THEN
      -- Même devise : le montant débité DOIT être la valeur reçue (anti-dérive).
      RETURN jsonb_build_object('success', false, 'error', 'DEBIT_MISMATCH',
        'expected', v_received_value, 'given', COALESCE(p_wallet_debit_amount, 0));
    END IF;
    IF COALESCE(p_wallet_debit_amount, 0) <= 0 THEN
      RETURN jsonb_build_object('success', false, 'error', 'INVALID_WALLET_AMOUNT');
    END IF;
    v_total_debit := p_wallet_debit_amount + COALESCE(p_buyer_fee_amount, 0);

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
    VALUES ('b2bp-' || left(replace(gen_random_uuid()::text, '-', ''), 44), v_buyer_user,
      v_supplier_user, 'payment', p_wallet_debit_amount, p_wallet_debit_amount, v_wallet_cur,
      'Paiement achat fournisseur B2B à la réception', 'completed',
      jsonb_build_object('order_id', v_purchase.linked_order_id, 'purchase_id', p_purchase_id,
        'received_value', v_received_value, 'purchase_currency', v_purchase.currency,
        'buyer_fee_amount', COALESCE(p_buyer_fee_amount, 0), 'source', 'receive_b2b_purchase'));

    -- Crédit fournisseur : valeur reçue, dans la devise de l'achat (conversion sûre).
    v_fee_res := public.credit_user_wallet_safe(v_supplier_user, v_received_value,
      COALESCE(v_purchase.currency, 'GNF'), 'b2b_purchase_payment', p_purchase_id::text);
    IF (v_fee_res->>'success')::boolean IS DISTINCT FROM true
       AND v_fee_res ? 'success' THEN
      RAISE EXCEPTION 'B2B_SUPPLIER_CREDIT_FAILED: %', COALESCE(v_fee_res->>'error', 'inconnu');
    END IF;

    IF COALESCE(p_buyer_fee_amount, 0) > 0 THEN
      BEGIN
        SELECT user_id INTO v_pdg_user FROM public.pdg_management WHERE is_active = true LIMIT 1;
        IF v_pdg_user IS NOT NULL THEN
          v_fee_res := public.credit_user_wallet_safe(v_pdg_user, p_buyer_fee_amount, v_wallet_cur);
          INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
            transaction_type, amount, net_amount, currency, description, status, metadata)
          VALUES ('fee-' || left(replace(gen_random_uuid()::text, '-', ''), 45), v_buyer_user,
            v_pdg_user, 'commission', p_buyer_fee_amount, p_buyer_fee_amount, v_wallet_cur,
            'Commission acheteur B2B (réception)', 'completed',
            jsonb_build_object('order_id', v_purchase.linked_order_id, 'purchase_id', p_purchase_id,
              'source', 'b2b_buyer_commission_reception'));
          UPDATE public.stock_purchases SET b2b_buyer_fee = b2b_buyer_fee + p_buyer_fee_amount
          WHERE id = p_purchase_id;
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;

    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date,
      payment_method, status, is_locked, purchase_reference)
    VALUES (v_buyer_user, v_desc, v_received_value, CURRENT_DATE, 'wallet', 'paid', true,
      v_order.order_number)
    RETURNING id INTO v_expense_id;

  ELSIF v_purchase.payment_mode = 'credit' THEN
    -- Dette sur la valeur RÉELLEMENT reçue (échéance/tranche fixées à la commande).
    INSERT INTO public.supplier_debts (vendor_id, supplier_id, purchase_id, total_amount,
      paid_amount, minimum_installment, due_date, currency, status)
    VALUES (p_buyer_vendor_id, v_purchase.supplier_id, p_purchase_id, v_received_value, 0,
      COALESCE(v_purchase.minimum_installment, 0), v_purchase.due_date,
      COALESCE(v_purchase.currency, 'GNF'), 'in_progress')
    RETURNING id INTO v_debt_id;

    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date,
      payment_method, status, is_locked, purchase_reference)
    VALUES (v_buyer_user, v_desc || ' (à crédit)', v_received_value, CURRENT_DATE,
      'credit', 'pending', true, v_order.order_number)
    RETURNING id INTO v_expense_id;

  ELSE
    -- cash / hors-app : dépense payée (marquage manuel du règlement réel).
    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date,
      payment_method, status, is_locked, purchase_reference)
    VALUES (v_buyer_user, v_desc, v_received_value, CURRENT_DATE, 'cash', 'paid', true,
      v_order.order_number)
    RETURNING id INTO v_expense_id;
  END IF;

  -- Fiche fournisseur protégée (achats aboutis) + clôture des deux objets.
  UPDATE public.vendor_suppliers SET has_validated_purchases = true
  WHERE id = v_purchase.supplier_id AND vendor_id = p_buyer_vendor_id;

  UPDATE public.orders SET status = 'delivered'::order_status, updated_at = now()
  WHERE id = v_purchase.linked_order_id;

  UPDATE public.stock_purchases
  SET status = 'received', received_at = now(), expense_id = v_expense_id,
      reception_report = jsonb_build_object('lines', v_report, 'gaps', v_gap_lines,
        'closed', true, 'closed_with_gap', jsonb_array_length(v_gap_lines) > 0, 'note', p_note),
      validated_at = now()
  WHERE id = p_purchase_id;

  RETURN jsonb_build_object('success', true, 'final', true, 'status', 'received',
    'report', v_report, 'gaps', v_gap_lines,
    'received_value', v_received_value, 'ordered_value', v_ordered_value,
    'debt_id', v_debt_id, 'expense_id', v_expense_id,
    'supplier_user_id', v_supplier_user, 'supplier_business_name', v_supplier_name,
    'order_number', v_order.order_number);
END;
$$;
REVOKE ALL ON FUNCTION public.receive_b2b_purchase(uuid, uuid, jsonb, boolean, text, numeric, text, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.receive_b2b_purchase(uuid, uuid, jsonb, boolean, text, numeric, text, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.receive_b2b_purchase(uuid, uuid, jsonb, boolean, text, numeric, text, numeric) TO service_role;

-- 3) ── validate_stock_purchase : PMP pour le flux EXTERNE (même signature) ──
-- Reprend 20260619100000 à l'identique, SAUF : cost_price passe au PMP (au lieu
-- d'être écrasé), via le helper commun. price (prix de vente) reste mis à jour.
CREATE OR REPLACE FUNCTION public.validate_stock_purchase(
  p_purchase_id uuid, p_vendor_id uuid, p_items jsonb, p_purchase_number text, p_total_amount numeric
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_user_id uuid; v_expense_id uuid; v_item jsonb;
  v_supplier_ids uuid[]; v_supplier_names text; v_desc text; v_purchase record;
  v_debt_supplier uuid; v_debt_id uuid; v_pmp jsonb; v_qty int;
BEGIN
  IF p_purchase_id IS NULL OR p_vendor_id IS NULL OR p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Paramètres manquants');
  END IF;

  SELECT user_id INTO v_user_id FROM public.vendors WHERE id = p_vendor_id;
  IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Vendor non trouvé'); END IF;

  SELECT id, status, is_locked, expense_id, payment_mode, supplier_id, due_date, minimum_installment
  INTO v_purchase FROM public.stock_purchases WHERE id = p_purchase_id AND vendor_id = p_vendor_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Achat introuvable pour ce vendeur'); END IF;
  IF v_purchase.status = 'validated' OR COALESCE(v_purchase.is_locked, false) = true THEN
    RETURN jsonb_build_object('success', true, 'already_validated', true, 'expense_id', v_purchase.expense_id, 'message', 'Achat déjà validé');
  END IF;

  SELECT array_agg(DISTINCT (e->>'supplier_id')::uuid) INTO v_supplier_ids
  FROM jsonb_array_elements(p_items) e WHERE NULLIF(e->>'supplier_id', '') IS NOT NULL;

  v_desc := 'Achat de stock - ' || p_purchase_number;
  IF v_supplier_ids IS NOT NULL AND array_length(v_supplier_ids, 1) > 0 THEN
    SELECT string_agg(name, ', ') INTO v_supplier_names FROM public.vendor_suppliers WHERE id = ANY(v_supplier_ids);
    IF v_supplier_names IS NOT NULL THEN v_desc := v_desc || ' - Fournisseur(s): ' || v_supplier_names; END IF;
  END IF;

  -- ── 1) Dépense / Dette selon le mode de paiement ──
  IF COALESCE(v_purchase.payment_mode, 'cash') = 'credit' THEN
    v_debt_supplier := COALESCE(v_purchase.supplier_id, v_supplier_ids[1]);
    INSERT INTO public.supplier_debts (vendor_id, supplier_id, purchase_id, total_amount, paid_amount,
      minimum_installment, due_date, status)
    VALUES (p_vendor_id, v_debt_supplier, p_purchase_id, p_total_amount, 0,
      COALESCE(v_purchase.minimum_installment, 0), v_purchase.due_date, 'in_progress')
    RETURNING id INTO v_debt_id;
    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date, payment_method, status, is_locked, purchase_reference)
    VALUES (v_user_id, v_desc || ' (à crédit)', p_total_amount, CURRENT_DATE, 'credit', 'pending', true, p_purchase_number)
    RETURNING id INTO v_expense_id;
  ELSE
    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date, payment_method, status, is_locked, purchase_reference)
    VALUES (v_user_id, v_desc, p_total_amount, CURRENT_DATE, 'cash', 'paid', true, p_purchase_number)
    RETURNING id INTO v_expense_id;
  END IF;

  -- ── 2) Stock en PMP + prix de vente (scopé vendeur) ──
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF NULLIF(v_item->>'product_id', '') IS NOT NULL THEN
      v_qty := COALESCE(NULLIF(v_item->>'quantity','')::numeric, 0)::int;
      IF v_qty > 0 THEN
        v_pmp := public.apply_purchase_to_product_stock(
          (v_item->>'product_id')::uuid, p_vendor_id, v_qty,
          COALESCE(NULLIF(v_item->>'purchase_price','')::numeric, 0));
        -- Produit d'un autre vendeur / introuvable → ligne ignorée (comportement
        -- historique : l'UPDATE scopé ne touchait rien non plus).
      END IF;
      UPDATE public.products SET
        price = COALESCE(NULLIF(v_item->>'selling_price', '')::numeric, price)
      WHERE id = (v_item->>'product_id')::uuid AND vendor_id = p_vendor_id;
    END IF;
  END LOOP;

  -- ── 3) fournisseurs marqués validés ──
  IF v_supplier_ids IS NOT NULL AND array_length(v_supplier_ids, 1) > 0 THEN
    UPDATE public.vendor_suppliers SET has_validated_purchases = true WHERE id = ANY(v_supplier_ids) AND vendor_id = p_vendor_id;
  END IF;

  -- ── 4) valider + verrouiller l'achat ──
  UPDATE public.stock_purchases SET status = 'validated', validated_at = NOW(), expense_id = v_expense_id, is_locked = true
  WHERE id = p_purchase_id;

  RETURN jsonb_build_object('success', true, 'expense_id', v_expense_id, 'debt_id', v_debt_id,
    'mode', COALESCE(v_purchase.payment_mode,'cash'),
    'message', 'Achat ' || p_purchase_number || ' validé' || CASE WHEN v_debt_id IS NOT NULL THEN ' (dette créée)' ELSE '' END);
END;
$$;
REVOKE ALL ON FUNCTION public.validate_stock_purchase(uuid, uuid, jsonb, text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validate_stock_purchase(uuid, uuid, jsonb, text, numeric) TO service_role;

-- 4) ── pay_supplier_debt : crédite le fournisseur LIÉ (même signature) ──────
-- Reprend 20260619210000 (débit idempotent + bascule dépense) et AJOUTE : si la
-- fiche fournisseur est liée à un vendeur 224 → crédit de SON wallet (transfert
-- réel tracé). Fournisseur externe : comportement inchangé (retrait, hors app).
CREATE OR REPLACE FUNCTION public.pay_supplier_debt(
  p_debt_id uuid, p_vendor_id uuid, p_amount numeric, p_idempotency_key text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_debt record; v_user_id uuid; v_new_paid numeric; v_new_status text; v_bal numeric;
  v_linked_user uuid; v_credit jsonb;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;

  SELECT user_id INTO v_user_id FROM public.vendors WHERE id = p_vendor_id;
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'VENDOR_NOT_FOUND'; END IF;

  SELECT * INTO v_debt FROM public.supplier_debts WHERE id = p_debt_id AND vendor_id = p_vendor_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEBT_NOT_FOUND'; END IF;
  IF v_debt.status NOT IN ('in_progress','overdue') THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'status', v_debt.status);
  END IF;
  IF p_amount > v_debt.remaining_amount + 0.01 THEN RAISE EXCEPTION 'AMOUNT_EXCEEDS_REMAINING'; END IF;

  -- Débit wallet vendeur (atomique, idempotent via wallet_debit_internal).
  v_bal := public.wallet_debit_internal(v_user_id, p_amount,
    'Règlement dette fournisseur', COALESCE(p_idempotency_key, 'debt_pay:' || p_debt_id::text || ':' || gen_random_uuid()::text));

  -- 🤝 Fournisseur LIÉ → transfert réel : crédit du wallet du fournisseur.
  SELECT v.user_id INTO v_linked_user
  FROM public.vendor_suppliers vs
  JOIN public.vendors v ON v.id = vs.linked_vendor_id
  WHERE vs.id = v_debt.supplier_id AND vs.link_status = 'linked';
  IF v_linked_user IS NOT NULL THEN
    v_credit := public.credit_user_wallet_safe(v_linked_user, p_amount,
      COALESCE(v_debt.currency, 'GNF'), 'b2b_debt_payment', p_debt_id::text);
    IF (v_credit->>'success')::boolean IS DISTINCT FROM true AND v_credit ? 'success' THEN
      RAISE EXCEPTION 'SUPPLIER_CREDIT_FAILED: %', COALESCE(v_credit->>'error', 'inconnu');
    END IF;
    INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
      transaction_type, amount, net_amount, currency, description, status, metadata)
    VALUES ('debt-' || left(replace(gen_random_uuid()::text, '-', ''), 44), v_user_id, v_linked_user,
      'payment', p_amount, p_amount, COALESCE(v_debt.currency, 'GNF'),
      'Règlement dette fournisseur B2B', 'completed',
      jsonb_build_object('debt_id', p_debt_id, 'purchase_id', v_debt.purchase_id,
        'source', 'pay_supplier_debt_linked'));
  END IF;

  v_new_paid := v_debt.paid_amount + p_amount;
  v_new_status := CASE WHEN v_new_paid >= v_debt.total_amount THEN 'paid' ELSE v_debt.status END;

  UPDATE public.supplier_debts SET paid_amount = v_new_paid, status = v_new_status, updated_at = now()
  WHERE id = p_debt_id;

  -- 🔗 Dette soldée → la dépense « à crédit » liée devient 'paid' (cohérence dépenses).
  IF v_new_status = 'paid' AND v_debt.purchase_id IS NOT NULL THEN
    UPDATE public.vendor_expenses e
       SET status = 'paid', payment_method = 'cash', updated_at = now()
      FROM public.stock_purchases sp
     WHERE sp.id = v_debt.purchase_id
       AND e.id = sp.expense_id
       AND e.status <> 'paid';
  END IF;

  RETURN jsonb_build_object('success', true, 'debt_id', p_debt_id, 'paid_amount', v_new_paid,
    'remaining', GREATEST(v_debt.total_amount - v_new_paid, 0), 'status', v_new_status,
    'new_balance', v_bal, 'linked_supplier_credited', v_linked_user IS NOT NULL);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
REVOKE ALL ON FUNCTION public.pay_supplier_debt(uuid, uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pay_supplier_debt(uuid, uuid, numeric, text) TO service_role;

SELECT 'Blocs 3+4 : réception B2B (partiel/total + PMP + finalisation paiement) + validate_stock_purchase PMP + pay_supplier_debt lié.' AS status;
