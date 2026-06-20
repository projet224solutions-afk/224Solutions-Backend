-- ============================================================================
-- FIX versement livreur : transaction_type 'delivery_earning' n'existe PAS dans
-- l'enum transaction_type → l'INSERT du ledger dans pay_restaurant_delivery échouait
-- (exception avalée par le trigger « WHEN OTHERS » → livreur jamais payé alors que la
-- commande passait completed). On recrée la fonction avec un type VALIDE ('payment'),
-- la traçabilité « gain de livraison » restant assurée par le metadata.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pay_restaurant_delivery(p_delivery_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  d            public.deliveries;
  o            public.restaurant_orders;
  v_owner      uuid;
  v_pdg        uuid;
  v_earning    numeric;
  v_margin     numeric;
  v_cur        text := 'GNF';
BEGIN
  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'LIVRAISON_INTROUVABLE'; END IF;
  IF d.restaurant_order_id IS NULL THEN RETURN jsonb_build_object('success', true, 'skipped', 'non_restaurant'); END IF;
  IF d.driver_id IS NULL OR d.status <> 'delivered' THEN RAISE EXCEPTION 'LIVRAISON_NON_LIVREE'; END IF;
  IF d.driver_paid_at IS NOT NULL THEN RETURN jsonb_build_object('success', true, 'already_paid', true); END IF;

  SELECT * INTO o FROM public.restaurant_orders WHERE id = d.restaurant_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMMANDE_INTROUVABLE'; END IF;
  IF COALESCE(o.delivery_fee, 0) <= 0 THEN
    UPDATE public.deliveries SET driver_paid_at = now() WHERE id = p_delivery_id;
    RETURN jsonb_build_object('success', true, 'fee', 0);
  END IF;

  v_earning := round(o.delivery_fee * 0.985);
  v_margin  := o.delivery_fee - v_earning;
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  IF o.delivery_fee_paid_by = 'restaurant' THEN
    SELECT user_id INTO v_owner FROM public.professional_services WHERE id = o.professional_service_id;
    PERFORM public.wallet_debit_internal(v_owner, o.delivery_fee, 'Frais de livraison (offerte)', 'resto_deliv:'||p_delivery_id::text);
    PERFORM public.credit_user_wallet_safe(d.driver_id, v_earning, v_cur);
    IF v_pdg IS NOT NULL AND v_margin > 0 THEN PERFORM public.credit_user_wallet_safe(v_pdg, v_margin, v_cur); END IF;
  ELSE
    IF v_pdg IS NOT NULL THEN
      PERFORM public.wallet_debit_internal(v_pdg, v_earning, 'Reversement livreur (frais séquestrés)', 'deliv_payout:'||p_delivery_id::text);
    END IF;
    PERFORM public.credit_user_wallet_safe(d.driver_id, v_earning, v_cur);
  END IF;

  INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id, amount, net_amount, currency, transaction_type, status, description, metadata)
  VALUES (generate_transaction_id(), v_pdg, d.driver_id, v_earning, v_earning, v_cur, 'payment', 'completed', 'Gain de livraison restaurant',
    jsonb_build_object('delivery_id', p_delivery_id, 'restaurant_order_id', d.restaurant_order_id, 'paid_by', o.delivery_fee_paid_by, 'kind', 'delivery_earning'));

  UPDATE public.deliveries SET driver_paid_at = now(), driver_earning = v_earning WHERE id = p_delivery_id;
  RETURN jsonb_build_object('success', true, 'driver_earning', v_earning, 'margin', v_margin);
END;
$$;

SELECT 'Fix versement livreur : transaction_type valide (payment + metadata kind=delivery_earning).' AS status;
