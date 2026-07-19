-- ============================================================================
-- B2B RÉCEPTION — les produits reçus arrivent COMPLETS (images + métadonnées)
-- + appariement auto par ligne (mémoire/code-barres/SKU/nom) mémorisé + atomicité.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.b2b_product_mapping (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_vendor_id uuid NOT NULL,
  supplier_product_id uuid NOT NULL,
  buyer_vendor_id uuid NOT NULL,
  buyer_product_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT b2b_product_mapping_uniq UNIQUE (supplier_product_id, buyer_vendor_id)
);
ALTER TABLE public.b2b_product_mapping ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS b2b_product_mapping_service_all ON public.b2b_product_mapping;
CREATE POLICY b2b_product_mapping_service_all ON public.b2b_product_mapping
  FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.receive_b2b_purchase(p_purchase_id uuid, p_buyer_vendor_id uuid, p_lines jsonb, p_close boolean DEFAULT false, p_note text DEFAULT NULL::text, p_wallet_debit_amount numeric DEFAULT 0, p_buyer_wallet_currency text DEFAULT NULL::text, p_buyer_fee_amount numeric DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_purchase record; v_order record; v_buyer_user uuid; v_supplier_user uuid;
  v_supplier_name text; v_line jsonb; v_item record; v_recv int;
  v_buyer_product uuid; v_np jsonb; v_pmp jsonb; v_sup record; v_created boolean;
  v_report jsonb := '[]'::jsonb; v_all_received boolean; v_final boolean;
  v_received_value numeric := 0; v_ordered_value numeric := 0;
  v_escrow record; v_rate numeric; v_shortfall numeric; v_release jsonb;
  v_bal numeric; v_wallet_cur text; v_total_debit numeric;
  v_pdg_user uuid; v_fee_res jsonb; v_debt_id uuid; v_expense_id uuid;
  v_desc text; v_no_dec boolean; v_gap_lines jsonb := '[]'::jsonb;
  v_refund_status text := NULL;
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

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    SELECT * INTO v_item FROM public.stock_purchase_items
    WHERE id = (v_line->>'item_id')::uuid AND purchase_id = p_purchase_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'B2B_RECV:LINE_NOT_FOUND:%', COALESCE(v_line->>'item_id','');
    END IF;

    v_recv := COALESCE((v_line->>'received_qty')::int, 0);
    IF v_recv < 0 THEN
      RAISE EXCEPTION 'B2B_RECV:INVALID_RECEIVED_QTY';
    END IF;
    IF v_recv > (v_item.quantity - v_item.received_quantity) THEN
      RAISE EXCEPTION 'B2B_RECV:RECEIVED_EXCEEDS_ORDERED:%', COALESCE(v_item.product_name,'');
    END IF;
    IF v_recv = 0 THEN CONTINUE; END IF;

    -- Produit FOURNISSEUR de la ligne (accès sûr : SELECT INTO met NULLs si aucun).
    SELECT * INTO v_sup FROM public.products WHERE id = v_item.supplier_product_id;
    v_buyer_product := COALESCE(NULLIF(v_line->>'buyer_product_id','')::uuid, v_item.product_id);
    v_created := false;
    IF v_buyer_product IS NOT NULL THEN
      PERFORM 1 FROM public.products WHERE id = v_buyer_product AND vendor_id = p_buyer_vendor_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'B2B_RECV:BUYER_PRODUCT_INVALID:%', COALESCE(v_item.product_name,'');
      END IF;
    ELSE
      v_np := v_line->'new_product';
      -- Appariement AUTO (silencieux) : mémoire b2b_product_mapping → code-barres → SKU → nom.
      IF v_item.supplier_product_id IS NOT NULL THEN
        SELECT m.buyer_product_id INTO v_buyer_product FROM public.b2b_product_mapping m
        WHERE m.supplier_product_id = v_item.supplier_product_id AND m.buyer_vendor_id = p_buyer_vendor_id
          AND EXISTS (SELECT 1 FROM public.products bp WHERE bp.id = m.buyer_product_id AND bp.vendor_id = p_buyer_vendor_id)
        LIMIT 1;
      END IF;
      IF v_buyer_product IS NULL AND COALESCE(v_sup.barcode,'') <> '' THEN
        SELECT id INTO v_buyer_product FROM public.products WHERE vendor_id = p_buyer_vendor_id AND barcode = v_sup.barcode LIMIT 1;
      END IF;
      IF v_buyer_product IS NULL AND COALESCE(v_sup.sku,'') <> '' THEN
        SELECT id INTO v_buyer_product FROM public.products WHERE vendor_id = p_buyer_vendor_id AND sku = v_sup.sku LIMIT 1;
      END IF;
      IF v_buyer_product IS NULL THEN
        SELECT id INTO v_buyer_product FROM public.products WHERE vendor_id = p_buyer_vendor_id AND lower(name) = lower(v_item.product_name) LIMIT 1;
      END IF;
      -- Sinon CRÉER en copiant images + métadonnées du produit fournisseur (propriété acheteur :
      -- l'array d'URL est repris ; supprimer la LIGNE produit fournisseur n'efface pas le fichier).
      IF v_buyer_product IS NULL THEN
        INSERT INTO public.products (vendor_id, name, price, stock_quantity, is_active, category_id,
          description, images, sku, barcode, weight, dimensions, tags,
          sell_by_carton, units_per_carton, barcode_value, barcode_format)
        VALUES (
          p_buyer_vendor_id,
          COALESCE(NULLIF(v_np->>'name',''), v_sup.name, v_item.product_name),
          GREATEST(COALESCE(NULLIF(v_np->>'selling_price','')::numeric, v_item.selling_price, v_item.purchase_price), 0),
          0, true,
          COALESCE(NULLIF(v_np->>'category_id','')::uuid, v_sup.category_id),
          v_sup.description, COALESCE(v_sup.images, ARRAY[]::text[]),
          CASE WHEN COALESCE(v_sup.sku,'') <> '' AND NOT EXISTS (SELECT 1 FROM public.products WHERE sku = v_sup.sku) THEN v_sup.sku ELSE NULL END,
          v_sup.barcode,
          v_sup.weight, v_sup.dimensions, v_sup.tags,
          COALESCE(v_sup.sell_by_carton, false), v_sup.units_per_carton, v_sup.barcode_value, v_sup.barcode_format)
        RETURNING id INTO v_buyer_product;
        v_created := true;
      END IF;
      -- Mémoriser l'appariement (idempotent) → 2e commande = auto & silencieux.
      IF v_item.supplier_product_id IS NOT NULL THEN
        INSERT INTO public.b2b_product_mapping (supplier_vendor_id, supplier_product_id, buyer_vendor_id, buyer_product_id)
        VALUES (COALESCE(v_sup.vendor_id, v_order.vendor_id), v_item.supplier_product_id, p_buyer_vendor_id, v_buyer_product)
        ON CONFLICT (supplier_product_id, buyer_vendor_id) DO UPDATE SET buyer_product_id = EXCLUDED.buyer_product_id;
      END IF;
    END IF;

    v_pmp := public.apply_purchase_to_product_stock(
      v_buyer_product, p_buyer_vendor_id, v_recv, v_item.purchase_price);
    IF (v_pmp->>'success')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'B2B_RECV:STOCK_ENTRY_FAILED:% (%)', COALESCE(v_item.product_name,''), COALESCE(v_pmp->>'error','');
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

  -- ══ FINALISATION ══
  v_desc := 'Achat fournisseur B2B - ' || v_order.order_number || ' - ' || COALESCE(v_supplier_name, '');

  IF v_purchase.payment_link_id IS NOT NULL THEN
    -- ── Achat issu d'un LIEN DE VENTE ──
    IF v_purchase.payment_mode = 'wallet' THEN
      -- Déjà réglé à l'acceptation. Écarts → remboursement fournisseur→acheteur
      -- (best-effort : l'échec ne bloque JAMAIS la réception, il est tracé).
      v_shortfall := GREATEST(v_ordered_value - v_received_value, 0);
      IF v_shortfall > 0 THEN
        BEGIN
          PERFORM public.wallet_debit_internal(v_supplier_user, v_shortfall,
            'Écarts réception lien de vente B2B ' || v_order.order_number,
            'b2bl-gap:' || p_purchase_id::text);
          v_fee_res := public.credit_user_wallet_safe(v_buyer_user, v_shortfall,
            COALESCE(v_purchase.currency, 'GNF'), 'b2b_link_gap_refund', p_purchase_id::text);
          INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
            transaction_type, amount, net_amount, currency, description, status, metadata)
          VALUES ('b2bg-' || left(replace(gen_random_uuid()::text, '-', ''), 44), v_supplier_user,
            v_buyer_user, 'refund', v_shortfall, v_shortfall, COALESCE(v_purchase.currency, 'GNF'),
            'Réception lien B2B — remboursement des écarts', 'completed',
            jsonb_build_object('purchase_id', p_purchase_id, 'order_id', v_purchase.linked_order_id,
              'source', 'receive_b2b_purchase_link_gap'));
          v_refund_status := 'refunded';
        EXCEPTION WHEN OTHERS THEN
          v_refund_status := 'refund_pending: ' || SQLERRM;
        END;
      END IF;
      INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date,
        payment_method, status, is_locked, purchase_reference)
      VALUES (v_buyer_user, v_desc || ' (lien de vente)', v_received_value, CURRENT_DATE,
        'wallet', 'paid', true, v_order.order_number)
      RETURNING id INTO v_expense_id;
    ELSE
      -- CRÉDIT : la dette existe depuis l'acceptation → ajustée à la valeur REÇUE
      -- (jamais sous le déjà-payé).
      UPDATE public.supplier_debts
      SET total_amount = GREATEST(v_received_value, paid_amount), updated_at = now()
      WHERE purchase_id = p_purchase_id AND status IN ('in_progress','overdue')
      RETURNING id INTO v_debt_id;
      INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date,
        payment_method, status, is_locked, purchase_reference)
      VALUES (v_buyer_user, v_desc || ' (lien de vente, à crédit)', v_received_value, CURRENT_DATE,
        'credit', 'pending', true, v_order.order_number)
      RETURNING id INTO v_expense_id;
    END IF;

  ELSIF v_purchase.payment_mode = 'wallet' AND v_purchase.payment_timing = 'on_order' THEN
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
    v_wallet_cur := COALESCE(p_buyer_wallet_currency, v_purchase.currency, 'GNF');
    IF upper(v_wallet_cur) = upper(COALESCE(v_purchase.currency, 'GNF'))
       AND COALESCE(p_wallet_debit_amount, 0) <> v_received_value THEN
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
    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date,
      payment_method, status, is_locked, purchase_reference)
    VALUES (v_buyer_user, v_desc, v_received_value, CURRENT_DATE, 'cash', 'paid', true,
      v_order.order_number)
    RETURNING id INTO v_expense_id;
  END IF;

  UPDATE public.vendor_suppliers SET has_validated_purchases = true
  WHERE id = v_purchase.supplier_id AND vendor_id = p_buyer_vendor_id;

  UPDATE public.orders SET status = 'delivered'::order_status, updated_at = now()
  WHERE id = v_purchase.linked_order_id;

  UPDATE public.stock_purchases
  SET status = 'received', received_at = now(), expense_id = v_expense_id,
      reception_report = jsonb_build_object('lines', v_report, 'gaps', v_gap_lines,
        'closed', true, 'closed_with_gap', jsonb_array_length(v_gap_lines) > 0, 'note', p_note,
        'refund_status', v_refund_status),
      validated_at = now()
  WHERE id = p_purchase_id;

  RETURN jsonb_build_object('success', true, 'final', true, 'status', 'received',
    'report', v_report, 'gaps', v_gap_lines,
    'received_value', v_received_value, 'ordered_value', v_ordered_value,
    'debt_id', v_debt_id, 'expense_id', v_expense_id, 'refund_status', v_refund_status,
    'supplier_user_id', v_supplier_user, 'supplier_business_name', v_supplier_name,
    'order_number', v_order.order_number);
END;
$function$

