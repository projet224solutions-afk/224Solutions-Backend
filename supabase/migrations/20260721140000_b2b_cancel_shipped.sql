-- ============================================================================
-- B2B — annulation d'une commande DÉJÀ EXPÉDIÉE (retour de marchandise).
--
-- Constat (audit) : cancel_b2b_order refusait `shipped` (INVALID_STATUS) → une commande
-- wallet/on_reception expédiée mais non réglée (l'acheteur n'a pas de fonds) restait
-- DÉFINITIVEMENT bloquée (cas ACH20260720-4448). Aucune transition de sortie de `shipped`
-- autre que received_partial/received.
--
-- Fix : on autorise l'annulation depuis `shipped`. À l'expédition, le stock a quitté
-- `stock_quantity` du fournisseur et la réservation a été soldée → annuler = RENDRE la
-- marchandise au stock VENDABLE du fournisseur (`stock_quantity += qty`, la réservation
-- n'existe plus à ce stade). Aucun débit acheteur (rien n'a été réglé pour wallet/on_reception ;
-- un escrow wallet/on_order éventuel reste remboursé par refund_order_escrow, inchangé).
--
-- SEULE différence vs la v2 (20260717210000) : `shipped` accepté dans la garde de statut
-- + un bloc de retour de stock pour `shipped`. Tout le reste est identique.
--
-- ✅ APPLIQUÉE EN PROD le 2026-07-21 (via API Management, preuve ROLLBACK sur la commande fantôme
--    ACH20260720-4448 : cancel → success, shipped→cancelled achat+commande, stock fournisseur +13).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.cancel_b2b_order(
  p_order_id uuid, p_caller_vendor_id uuid, p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_order record; v_purchase record; v_line record; v_refund jsonb;
  v_is_supplier boolean; v_is_buyer boolean; v_new_status text;
  v_other record; v_buyer_user uuid; v_supplier_user uuid; v_debt record; v_res jsonb;
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
  -- ⬇️ `shipped` désormais annulable (retour de marchandise). received/received_partial NON
  --    (la marchandise est déjà entrée chez l'acheteur → passe par litige/reliquat).
  IF v_purchase.status NOT IN ('ordered','adjusted','confirmed','shipped') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_STATUS', 'status', v_purchase.status);
  END IF;

  -- Achat issu d'un LIEN : défaire l'argent AVANT de toucher au stock.
  IF v_purchase.payment_link_id IS NOT NULL THEN
    SELECT v.user_id INTO v_buyer_user FROM public.vendors v WHERE v.id = v_purchase.vendor_id;
    SELECT v.user_id INTO v_supplier_user FROM public.vendors v WHERE v.id = v_order.vendor_id;
    IF v_purchase.payment_mode = 'wallet' THEN
      BEGIN
        PERFORM public.wallet_debit_internal(v_supplier_user, COALESCE(v_order.total_amount, 0),
          'Annulation lien de vente B2B ' || v_order.order_number,
          'b2bl-cancel:' || v_purchase.id::text);
      EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'error', 'SUPPLIER_REFUND_FAILED',
          'detail', SQLERRM);
      END;
      v_res := public.credit_user_wallet_safe(v_buyer_user, COALESCE(v_order.total_amount, 0),
        COALESCE(v_purchase.currency, 'GNF'), 'b2b_link_cancel_refund', v_purchase.id::text);
      INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id,
        transaction_type, amount, net_amount, currency, description, status, metadata)
      VALUES ('b2bc-' || left(replace(gen_random_uuid()::text, '-', ''), 44), v_supplier_user,
        v_buyer_user, 'refund', COALESCE(v_order.total_amount, 0), COALESCE(v_order.total_amount, 0),
        COALESCE(v_purchase.currency, 'GNF'), 'Annulation lien de vente B2B — remboursement acheteur',
        'completed', jsonb_build_object('order_id', p_order_id, 'purchase_id', v_purchase.id,
          'payment_link_id', v_purchase.payment_link_id, 'source', 'cancel_b2b_order_link'));
    ELSE
      SELECT * INTO v_debt FROM public.supplier_debts
      WHERE purchase_id = v_purchase.id AND status IN ('in_progress','overdue') FOR UPDATE;
      IF FOUND THEN
        IF v_debt.paid_amount > 0 THEN
          RETURN jsonb_build_object('success', false, 'error', 'DEBT_PARTIALLY_PAID');
        END IF;
        UPDATE public.supplier_debts SET status = 'cancelled', updated_at = now() WHERE id = v_debt.id;
      END IF;
    END IF;
  END IF;

  -- Libérer la réservation si la commande était confirmée (le stock n'est pas encore parti).
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

  -- Annulation d'une commande DÉJÀ EXPÉDIÉE : à l'expédition le stock a quitté stock_quantity
  -- et la réservation a été soldée → on REND la marchandise au stock vendable du fournisseur
  -- (aucune réservation à décrémenter ici). Traçabilité assurée par cancelled_at/cancel_reason
  -- ci-dessous + la notification côté route (createNotification 'b2b_order_cancelled').
  IF v_purchase.status = 'shipped' THEN
    FOR v_line IN
      SELECT oi.product_id, SUM(oi.quantity)::int AS qty
      FROM public.order_items oi WHERE oi.order_id = p_order_id GROUP BY oi.product_id
    LOOP
      UPDATE public.products
      SET stock_quantity = COALESCE(stock_quantity, 0) + v_line.qty, updated_at = now()
      WHERE id = v_line.product_id;
    END LOOP;
  END IF;

  -- Escrow wallet classique éventuel (achats hors lien) — pour wallet/on_reception, rien à rembourser.
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

  IF v_is_supplier THEN
    SELECT v.user_id, v.business_name INTO v_other FROM public.vendors v WHERE v.id = v_purchase.vendor_id;
  ELSE
    SELECT v.user_id, v.business_name INTO v_other FROM public.vendors v WHERE v.id = v_order.vendor_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'new_status', v_new_status,
    'order_number', v_order.order_number, 'purchase_id', v_purchase.id,
    'cancelled_by', CASE WHEN v_is_supplier THEN 'supplier' ELSE 'buyer' END,
    'other_user_id', v_other.user_id, 'other_business_name', v_other.business_name,
    'refunded_amount', COALESCE((v_refund->>'refunded_amount')::numeric,
      CASE WHEN v_purchase.payment_link_id IS NOT NULL AND v_purchase.payment_mode = 'wallet'
           THEN COALESCE(v_order.total_amount, 0) ELSE 0 END));
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_b2b_order(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_b2b_order(uuid, uuid, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_b2b_order(uuid, uuid, text) TO service_role;

SELECT 'cancel_b2b_order : shipped désormais annulable (retour de marchandise au stock vendable du fournisseur).' AS status;
