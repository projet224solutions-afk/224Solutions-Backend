-- ============================================================================
-- FIX MONÉTAIRE — cancel_restaurant_order ne remboursait que les PLATS (v_o.total),
-- pas les FRAIS DE LIVRAISON payés par le client (séquestrés chez le PDG au paiement).
-- → à l'annulation/refus d'une commande livraison payée, le client PERDAIT ses frais
-- (prouvé e2e : client −1000, PDG +1000). L'annulation n'étant possible qu'AVANT livraison,
-- le livreur n'a jamais été payé → on peut sûrement reprendre le séquestre au PDG.
-- Correctif : rembourser aussi delivery_fee (si payé par le client) + reprise PDG.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.cancel_restaurant_order(
  p_order_id uuid,
  p_reason   text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_o     public.restaurant_orders;
  v_owner uuid;
  v_pdg   uuid;
  v_key   text;
  v_refunded numeric := 0;
BEGIN
  SELECT * INTO v_o FROM public.restaurant_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMMANDE_INTROUVABLE'; END IF;
  IF v_o.payment_status = 'refunded' OR v_o.status = 'cancelled' THEN
    RETURN jsonb_build_object('success', true, 'already_refunded', true);
  END IF;
  IF v_o.status NOT IN ('pending','accepted','confirmed') THEN RAISE EXCEPTION 'ANNULATION_IMPOSSIBLE'; END IF;

  IF v_o.payment_status = 'paid' THEN
    v_key := 'resto_refund:' || p_order_id::text;
    SELECT user_id INTO v_owner FROM public.professional_services WHERE id = v_o.professional_service_id;
    SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

    -- (1) Rembourser les PLATS au client + reprise resto (net) / PDG (commission).
    PERFORM public.credit_user_wallet_safe(v_o.customer_user_id, v_o.total, 'GNF');
    INSERT INTO public.wallet_transactions (transaction_id, receiver_user_id, amount, net_amount, currency, transaction_type, status, description, metadata)
    VALUES (generate_transaction_id(), v_o.customer_user_id, v_o.total, v_o.total, 'GNF', 'refund', 'completed', 'Remboursement commande restaurant annulée',
      jsonb_build_object('order_id', p_order_id, 'reason', p_reason));
    IF v_owner IS NOT NULL THEN
      PERFORM public.wallet_debit_internal(v_owner, v_o.total - COALESCE(v_o.commission,0), 'Annulation commande restaurant', v_key||':owner');
    END IF;
    IF v_pdg IS NOT NULL AND COALESCE(v_o.commission,0) > 0 THEN
      PERFORM public.wallet_debit_internal(v_pdg, v_o.commission, 'Annulation commission restaurant', v_key||':pdg');
    END IF;
    v_refunded := v_o.total;

    -- (2) Rembourser les FRAIS DE LIVRAISON si payés par le client (séquestre PDG, livreur non payé).
    IF COALESCE(v_o.delivery_fee, 0) > 0 AND v_o.delivery_fee_paid_by = 'client' THEN
      PERFORM public.credit_user_wallet_safe(v_o.customer_user_id, v_o.delivery_fee, 'GNF');
      INSERT INTO public.wallet_transactions (transaction_id, receiver_user_id, amount, net_amount, currency, transaction_type, status, description, metadata)
      VALUES (generate_transaction_id(), v_o.customer_user_id, v_o.delivery_fee, v_o.delivery_fee, 'GNF', 'refund', 'completed', 'Remboursement frais de livraison (annulation)',
        jsonb_build_object('order_id', p_order_id, 'reason', p_reason, 'kind', 'delivery_fee'));
      IF v_pdg IS NOT NULL THEN
        PERFORM public.wallet_debit_internal(v_pdg, v_o.delivery_fee, 'Annulation frais de livraison (séquestre)', v_key||':deliv');
      END IF;
      v_refunded := v_refunded + v_o.delivery_fee;
    END IF;
  END IF;

  UPDATE public.restaurant_orders
  SET status         = 'cancelled',
      cancelled_reason = p_reason,
      cancelled_at   = now(),
      payment_status = CASE WHEN v_o.payment_status = 'paid' THEN 'refunded' ELSE v_o.payment_status END,
      updated_at     = now()
  WHERE id = p_order_id;

  RETURN jsonb_build_object('success', true, 'refunded', v_refunded);
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_restaurant_order(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_restaurant_order(uuid, text) TO service_role;

SELECT 'Fix : cancel_restaurant_order rembourse aussi les frais de livraison séquestrés (net 0 client).' AS status;
