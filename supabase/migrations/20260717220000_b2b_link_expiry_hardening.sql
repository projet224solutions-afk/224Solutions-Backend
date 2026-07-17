-- ============================================================================
-- 🔧 ESPACE GROSSISTE 224 — durcissement expiration des liens adossés au stock
-- ----------------------------------------------------------------------------
-- TROUVAILLE DE CERTIFICATION (T3 du harnais liens) : le trigger existant
-- trigger_check_payment_link_expiry (BEFORE UPDATE) force status='expired' dès
-- que expires_at < now() sur N'IMPORTE QUEL update d'un lien pending (y compris
-- le simple marquage viewed_at du /resolve). Un lien b2b_stock RÉSERVÉ pouvait
-- donc passer 'expired' SANS libérer sa réservation → stock fantôme.
--
-- Correctif (sans toucher le trigger — il sert les liens classiques) :
--   1) expire_b2b_stock_links v2 : traite AUSSI les liens déjà 'expired' /
--      'cancelled' porteurs d'une réservation orpheline (stock_reserved=true,
--      use_count=0). Idempotence : stock_reserved passe à false après libération.
--   2) cancel_b2b_stock_link v2 : marque stock_reserved=false après libération.
--   3) accept_b2b_stock_link : quand un lien réservé usage-unique est accepté,
--      stock_reserved=false (la réservation appartient désormais à la COMMANDE
--      confirmée — plus jamais au lien).
--
-- 2e TROUVAILLE (T6) : la policy supplier_debts_creditor sous-requêtait
-- vendor_suppliers… soumise à SA PROPRE RLS (le créancier n'est pas le
-- propriétaire de la fiche) → il ne voyait AUCUNE créance. Correctif : la
-- jointure passe par une fonction SECURITY DEFINER dédiée.
-- ============================================================================

-- 0) ── Policy créancier réparée (sous-requête via SECURITY DEFINER) ─────────
CREATE OR REPLACE FUNCTION public.b2b_creditor_supplier_rows(p_user uuid)
RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT vs.id
  FROM public.vendor_suppliers vs
  JOIN public.vendors v ON v.id = vs.linked_vendor_id
  WHERE v.user_id = p_user AND vs.link_status = 'linked';
$$;
REVOKE ALL ON FUNCTION public.b2b_creditor_supplier_rows(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.b2b_creditor_supplier_rows(uuid) TO authenticated, service_role;

DROP POLICY IF EXISTS supplier_debts_creditor ON public.supplier_debts;
CREATE POLICY supplier_debts_creditor ON public.supplier_debts
  FOR SELECT TO authenticated
  USING (supplier_id IN (SELECT public.b2b_creditor_supplier_rows(auth.uid())));

-- 1) ── expire_b2b_stock_links v2 ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.expire_b2b_stock_links()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_link public.payment_links%ROWTYPE; v_count int := 0; v_released int := 0;
BEGIN
  FOR v_link IN
    SELECT * FROM public.payment_links
    WHERE link_type = 'b2b_stock'
      AND (
        (status = 'pending' AND expires_at < now())
        -- Réservations ORPHELINES : liens expirés au vol par le trigger
        -- check_payment_link_expiry, ou annulés hors RPC, jamais utilisés.
        OR (status IN ('expired','cancelled') AND stock_reserved AND COALESCE(use_count, 0) = 0)
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    IF v_link.stock_reserved AND COALESCE(v_link.use_count, 0) = 0 THEN
      PERFORM public.b2b_release_link_reservation(v_link);
      v_released := v_released + 1;
    END IF;
    UPDATE public.payment_links
    SET status = CASE WHEN status = 'pending' THEN 'expired' ELSE status END,
        stock_reserved = false, updated_at = now()
    WHERE id = v_link.id;
    v_count := v_count + 1;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'expired', v_count, 'released', v_released);
END;
$$;
REVOKE ALL ON FUNCTION public.expire_b2b_stock_links() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.expire_b2b_stock_links() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_b2b_stock_links() TO service_role;

-- 2) ── cancel_b2b_stock_link v2 (idempotence de libération) ─────────────────
CREATE OR REPLACE FUNCTION public.cancel_b2b_stock_link(
  p_link_id uuid, p_supplier_vendor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_link public.payment_links%ROWTYPE; v_released boolean := false;
BEGIN
  SELECT * INTO v_link FROM public.payment_links
  WHERE id = p_link_id AND vendeur_id = p_supplier_vendor_id AND link_type = 'b2b_stock'
  FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'LINK_NOT_FOUND'); END IF;

  -- Libération même si le trigger l'a déjà basculé 'expired' (réservation orpheline).
  IF v_link.stock_reserved AND COALESCE(v_link.use_count, 0) = 0 THEN
    PERFORM public.b2b_release_link_reservation(v_link);
    v_released := true;
  END IF;

  IF v_link.status = 'pending' THEN
    UPDATE public.payment_links
    SET status = 'cancelled', stock_reserved = false, updated_at = now()
    WHERE id = p_link_id;
    RETURN jsonb_build_object('success', true, 'released', v_released);
  END IF;

  UPDATE public.payment_links SET stock_reserved = false, updated_at = now() WHERE id = p_link_id;
  RETURN jsonb_build_object('success', true, 'already', true, 'status', v_link.status,
    'released', v_released);
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_b2b_stock_link(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_b2b_stock_link(uuid, uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_b2b_stock_link(uuid, uuid) TO service_role;

-- 3) ── accept : la réservation change de propriétaire (lien → commande) ─────
-- On ne redéfinit PAS accept_b2b_stock_link en entier : on pose la règle par un
-- UPDATE complémentaire encapsulé, appelé à la fin des deux chemins (wallet via
-- settle ne touche pas stock_reserved ; credit met à jour le lien lui-même).
-- → Implémenté par un patch ciblé de accept_b2b_stock_link (seules les lignes
--   de comptabilité du lien changent : stock_reserved = false).
DO $$
DECLARE v_src text;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'accept_b2b_stock_link';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'accept_b2b_stock_link absente — appliquer 20260717210000 d''abord';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.accept_b2b_stock_link(
  p_link_id uuid, p_buyer_user_id uuid, p_buyer_vendor_id uuid, p_customer_id uuid,
  p_mode text, p_buyer_fee numeric DEFAULT 0
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_link public.payment_links%ROWTYPE;
  v_supplier record; v_buyer record; v_supplier_row uuid;
  v_item jsonb; v_pid uuid; v_qty int; v_price numeric; v_stock int;
  v_total numeric; v_order_id uuid; v_purchase_id uuid; v_order_number text;
  v_settle jsonb; v_debt_id uuid; v_exhausted boolean;
  v_pdg_user uuid; v_fee_res jsonb; v_bal numeric; v_cur text;
BEGIN
  IF p_mode NOT IN ('wallet','credit') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODE');
  END IF;

  SELECT * INTO v_link FROM public.payment_links
  WHERE id = p_link_id AND link_type = 'b2b_stock' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'LINK_NOT_FOUND'); END IF;
  IF v_link.status <> 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'LINK_NOT_PAYABLE', 'status', v_link.status);
  END IF;
  IF v_link.expires_at < now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'LINK_EXPIRED');
  END IF;
  IF v_link.is_single_use AND COALESCE(v_link.use_count, 0) > 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'LINK_ALREADY_USED');
  END IF;
  IF v_link.max_uses IS NOT NULL AND COALESCE(v_link.use_count, 0) >= v_link.max_uses THEN
    RETURN jsonb_build_object('success', false, 'error', 'LINK_EXHAUSTED');
  END IF;
  IF v_link.target_vendor_id IS NOT NULL AND v_link.target_vendor_id <> p_buyer_vendor_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_TARGET');
  END IF;
  IF p_mode = 'credit' AND NOT COALESCE(v_link.allow_credit, false) THEN
    RETURN jsonb_build_object('success', false, 'error', 'CREDIT_NOT_ALLOWED');
  END IF;

  SELECT id, user_id, business_name INTO v_supplier FROM public.vendors WHERE id = v_link.vendeur_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_GONE'); END IF;
  SELECT id, user_id, business_name INTO v_buyer FROM public.vendors WHERE id = p_buyer_vendor_id;
  IF NOT FOUND OR v_buyer.user_id <> p_buyer_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'BUYER_VENDOR_INVALID');
  END IF;
  IF p_buyer_vendor_id = v_link.vendeur_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'OWN_LINK');
  END IF;

  SELECT id INTO v_supplier_row FROM public.vendor_suppliers
  WHERE vendor_id = p_buyer_vendor_id AND linked_vendor_id = v_link.vendeur_id;
  IF v_supplier_row IS NULL THEN
    INSERT INTO public.vendor_suppliers (vendor_id, name, supplier_kind, linked_vendor_id, link_status)
    VALUES (p_buyer_vendor_id, v_supplier.business_name, 'lie', v_link.vendeur_id, 'linked')
    RETURNING id INTO v_supplier_row;
  ELSE
    UPDATE public.vendor_suppliers
    SET supplier_kind = 'lie', link_status = 'linked', updated_at = now()
    WHERE id = v_supplier_row AND link_status <> 'linked';
  END IF;

  v_total := 0;
  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(v_link.metadata->'items', '[]'::jsonb)) LOOP
    v_pid := NULLIF(v_item->>'product_id', '')::uuid;
    v_qty := COALESCE((v_item->>'qty')::int, 0);
    v_price := COALESCE((v_item->>'price')::numeric, 0);
    IF v_pid IS NULL OR v_qty <= 0 THEN CONTINUE; END IF;
    v_total := v_total + (v_price * v_qty);
    IF NOT (v_link.stock_reserved AND COALESCE(v_link.is_single_use, false)) THEN
      SELECT stock_quantity INTO v_stock FROM public.products WHERE id = v_pid FOR UPDATE;
      IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'PRODUCT_GONE', 'product_id', v_pid);
      END IF;
      IF COALESCE(v_stock, 0) < v_qty THEN
        RETURN jsonb_build_object('success', false, 'error', 'STOCK_INSUFFICIENT',
          'product_name', v_item->>'name', 'available', COALESCE(v_stock, 0));
      END IF;
      UPDATE public.products
      SET stock_quantity = stock_quantity - v_qty,
          reserved_quantity = reserved_quantity + v_qty,
          updated_at = now()
      WHERE id = v_pid;
    END IF;
  END LOOP;
  IF v_total <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_TOTAL');
  END IF;

  v_order_number := 'B2B-' || to_char(now(), 'YYMMDD') || '-' ||
                    upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  v_cur := upper(COALESCE(v_link.devise, 'GNF'));
  INSERT INTO public.orders (order_number, customer_id, vendor_id, status, payment_status,
    payment_method, subtotal, total_amount, shipping_address, currency, source, order_type, metadata)
  VALUES (v_order_number, p_customer_id, v_link.vendeur_id, 'confirmed'::order_status,
    CASE WHEN p_mode = 'wallet' THEN 'paid'::payment_status ELSE 'pending'::payment_status END,
    CASE WHEN p_mode = 'wallet' THEN 'wallet'::payment_method ELSE 'cash'::payment_method END,
    v_total, v_total, '{}'::jsonb, v_cur, 'online'::order_source, 'b2b_purchase',
    jsonb_build_object('b2b', true, 'buyer_vendor_id', p_buyer_vendor_id,
      'buyer_business_name', v_buyer.business_name,
      'payment_mode', p_mode, 'payment_link_id', v_link.id,
      'payment_link_payment_id', v_link.payment_id))
  RETURNING id INTO v_order_id;

  INSERT INTO public.order_items (order_id, product_id, product_name, quantity, unit_price, total_price)
  SELECT v_order_id, NULLIF(l->>'product_id','')::uuid, l->>'name', (l->>'qty')::int,
         (l->>'price')::numeric, (l->>'price')::numeric * (l->>'qty')::int
  FROM jsonb_array_elements(COALESCE(v_link.metadata->'items', '[]'::jsonb)) AS l
  WHERE COALESCE((l->>'qty')::int, 0) > 0;

  INSERT INTO public.stock_purchases (vendor_id, purchase_number, status, supplier_id,
    payment_mode, payment_timing, currency, due_date, minimum_installment,
    linked_order_id, b2b_buyer_fee, is_locked, confirmed_at, payment_link_id, notes)
  VALUES (p_buyer_vendor_id, v_order_number, 'confirmed', v_supplier_row,
    p_mode, NULL, v_cur,
    CASE WHEN p_mode = 'credit' THEN CURRENT_DATE + COALESCE(v_link.credit_due_days, 0) ELSE NULL END,
    0, v_order_id, COALESCE(p_buyer_fee, 0), true, now(), v_link.id,
    'Lien de vente ' || v_link.payment_id || COALESCE(' — ' || v_link.title, ''))
  RETURNING id INTO v_purchase_id;

  INSERT INTO public.stock_purchase_items (purchase_id, supplier_id, supplier_product_id,
    product_name, quantity, purchase_price, selling_price)
  SELECT v_purchase_id, v_supplier_row, NULLIF(l->>'product_id','')::uuid, l->>'name',
         (l->>'qty')::int, (l->>'price')::numeric, (l->>'price')::numeric
  FROM jsonb_array_elements(COALESCE(v_link.metadata->'items', '[]'::jsonb)) AS l
  WHERE COALESCE((l->>'qty')::int, 0) > 0;

  UPDATE public.orders SET metadata = metadata || jsonb_build_object('purchase_id', v_purchase_id)
  WHERE id = v_order_id;

  IF p_mode = 'wallet' THEN
    v_settle := public.settle_payment_link_atomic(
      p_buyer_user_id, v_supplier.user_id, v_total, 0, v_cur,
      v_link.payment_id, 'b2bl:' || v_link.id::text || ':' || v_purchase_id::text,
      'Lien de vente B2B ' || v_link.payment_id);

    IF COALESCE(p_buyer_fee, 0) > 0 THEN
      SELECT balance INTO v_bal FROM public.wallets
      WHERE user_id = p_buyer_user_id AND currency = v_cur FOR UPDATE;
      IF NOT FOUND OR v_bal < p_buyer_fee THEN
        RAISE EXCEPTION 'INSUFFICIENT_FUNDS';
      END IF;
      UPDATE public.wallets SET balance = balance - p_buyer_fee, updated_at = now()
      WHERE user_id = p_buyer_user_id AND currency = v_cur;
      BEGIN
        SELECT user_id INTO v_pdg_user FROM public.pdg_management WHERE is_active = true LIMIT 1;
        IF v_pdg_user IS NOT NULL THEN
          v_fee_res := public.credit_user_wallet_safe(v_pdg_user, p_buyer_fee, v_cur);
          INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
            transaction_type, amount, net_amount, currency, description, status, metadata)
          VALUES ('fee-' || left(replace(gen_random_uuid()::text, '-', ''), 45), p_buyer_user_id,
            v_pdg_user, 'commission', p_buyer_fee, p_buyer_fee, v_cur,
            'Commission acheteur B2B (lien de vente)', 'completed',
            jsonb_build_object('order_id', v_order_id, 'purchase_id', v_purchase_id,
              'payment_link_id', v_link.id, 'source', 'b2b_link_buyer_commission'));
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;

    -- La réservation appartient désormais à la COMMANDE confirmée, plus au lien.
    IF v_link.stock_reserved AND COALESCE(v_link.is_single_use, false) THEN
      UPDATE public.payment_links SET stock_reserved = false WHERE id = v_link.id;
    END IF;
  ELSE
    INSERT INTO public.supplier_debts (vendor_id, supplier_id, purchase_id, total_amount,
      paid_amount, minimum_installment, due_date, currency, status)
    VALUES (p_buyer_vendor_id, v_supplier_row, v_purchase_id, v_total, 0, 0,
      CURRENT_DATE + COALESCE(v_link.credit_due_days, 0), v_cur, 'in_progress')
    RETURNING id INTO v_debt_id;

    v_exhausted := COALESCE(v_link.is_single_use, false)
      OR (v_link.max_uses IS NOT NULL AND COALESCE(v_link.use_count, 0) + 1 >= v_link.max_uses);
    UPDATE public.payment_links
       SET status = CASE WHEN v_exhausted THEN 'success' ELSE status END,
           use_count = COALESCE(use_count, 0) + 1,
           gross_amount = COALESCE(gross_amount, 0) + v_total,
           stock_reserved = CASE WHEN v_link.stock_reserved AND COALESCE(v_link.is_single_use, false)
                                 THEN false ELSE stock_reserved END,
           updated_at = now()
     WHERE id = v_link.id;
  END IF;

  RETURN jsonb_build_object('success', true, 'order_id', v_order_id, 'purchase_id', v_purchase_id,
    'order_number', v_order_number, 'total', v_total, 'currency', v_cur, 'mode', p_mode,
    'debt_id', v_debt_id, 'supplier_user_id', v_supplier.user_id,
    'supplier_business_name', v_supplier.business_name,
    'buyer_business_name', v_buyer.business_name,
    'link_payment_id', v_link.payment_id);
END;
$$;
REVOKE ALL ON FUNCTION public.accept_b2b_stock_link(uuid, uuid, uuid, uuid, text, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.accept_b2b_stock_link(uuid, uuid, uuid, uuid, text, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.accept_b2b_stock_link(uuid, uuid, uuid, uuid, text, numeric) TO service_role;

SELECT 'Durcissement expiration liens B2B : réservations orphelines rattrapées (trigger check_payment_link_expiry), libération idempotente (stock_reserved=false).' AS status;
