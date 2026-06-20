-- ============================================================================
-- FIX MONÉTAIRE — cancel_restaurant_order remboursait TOUJOURS le client, même pour une
-- commande NON PAYÉE (dine_in/à emporter réglés EN PERSONNE : payment_status='pending').
-- → un client connecté annulé se voyait créditer de l'argent jamais versé (création de monnaie).
-- Correctif : le remboursement (crédit client + reprise resto/PDG) ne s'effectue QUE si la
-- commande était réellement PAYÉE (payment_status='paid'). Sinon, simple annulation, zéro mouvement.
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

  -- REMBOURSEMENT uniquement si la commande a été PAYÉE (wallet). Sinon (réglée en personne ou pas
  -- encore réglée) : AUCUN mouvement d'argent, on annule simplement.
  IF v_o.payment_status = 'paid' THEN
    v_key := 'resto_refund:' || p_order_id::text;

    -- Rembourser le client + ligne d'historique.
    PERFORM public.credit_user_wallet_safe(v_o.customer_user_id, v_o.total, 'GNF');
    INSERT INTO public.wallet_transactions (
      transaction_id, receiver_user_id, amount, net_amount, currency, transaction_type, status, description, metadata)
    VALUES (
      generate_transaction_id(), v_o.customer_user_id, v_o.total, v_o.total, 'GNF',
      'refund', 'completed', 'Remboursement commande restaurant annulée',
      jsonb_build_object('order_id', p_order_id, 'reason', p_reason));

    -- Reprendre au restaurant (net) et au PDG (commission) ce qui avait été crédité (double-entrée).
    SELECT user_id INTO v_owner FROM public.professional_services WHERE id = v_o.professional_service_id;
    IF v_owner IS NOT NULL THEN
      PERFORM public.wallet_debit_internal(v_owner, v_o.total - COALESCE(v_o.commission,0), 'Annulation commande restaurant', v_key||':owner');
    END IF;
    SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
    IF v_pdg IS NOT NULL AND COALESCE(v_o.commission,0) > 0 THEN
      PERFORM public.wallet_debit_internal(v_pdg, v_o.commission, 'Annulation commission restaurant', v_key||':pdg');
    END IF;

    v_refunded := v_o.total;
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

SELECT 'Fix : cancel_restaurant_order ne rembourse QUE les commandes payées (plus de crédit fantôme sur les commandes en personne).' AS status;
