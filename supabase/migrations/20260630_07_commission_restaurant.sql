-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 4 (flux RESTAURANT) — commission agent sur la commande restaurant en ligne.
-- ════════════════════════════════════════════════════════════════════════════
-- process_restaurant_order crédite DÉJÀ le PDG de v_commission (sur les plats, L106)
-- → on ajoute credit_agent_commission (débite 20%, Étape 1) → net 80/20. Paiement
-- wallet (payment_method='wallet') = toujours EN LIGNE. Idempotent par order_id.
-- Fonction reproduite À L'IDENTIQUE + l'appel commission avant le RETURN (non bloquant).
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.process_restaurant_order(
  p_client_id               uuid,
  p_professional_service_id uuid,
  p_amount                  numeric,
  p_items                   jsonb,
  p_order_type              text,
  p_table_number            integer,
  p_delivery_address        text,
  p_special_note            text,
  p_idempotency_key         text,
  p_delivery_fee            numeric DEFAULT 0,
  p_delivery_paid_by        text    DEFAULT 'client'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_existing    public.restaurant_orders;
  v_owner       uuid;
  v_pdg         uuid;
  v_rate        numeric;
  v_commission  numeric;
  v_net         numeric;
  v_otype       text;
  v_order_id    uuid;
  v_owner_res   jsonb;
  v_got         numeric;
  v_cur         text := 'GNF';
  v_fee         numeric := GREATEST(0, COALESCE(p_delivery_fee, 0));
  v_fee_payer   text := CASE WHEN p_delivery_paid_by = 'restaurant' THEN 'restaurant' ELSE 'client' END;
  v_client_fee  numeric;   -- frais effectivement débités au client (0 si offerte)
  v_debit       numeric;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) < 8 THEN RAISE EXCEPTION 'IDEMPOTENCY_REQUISE'; END IF;

  v_otype := CASE p_order_type WHEN 'pickup' THEN 'takeaway' WHEN 'table' THEN 'dine_in' ELSE p_order_type END;
  IF v_otype NOT IN ('delivery','dine_in','takeaway') THEN RAISE EXCEPTION 'TYPE_INVALIDE'; END IF;
  -- Les frais ne s'appliquent qu'à la livraison.
  IF v_otype <> 'delivery' THEN v_fee := 0; END IF;
  v_client_fee := CASE WHEN v_fee_payer = 'client' THEN v_fee ELSE 0 END;

  SELECT * INTO v_existing FROM public.restaurant_orders WHERE idempotency_key = p_idempotency_key LIMIT 1;
  IF FOUND THEN
    RETURN COALESCE(v_existing.payment_result, jsonb_build_object('success', true, 'order_id', v_existing.id, 'idempotent', true));
  END IF;

  SELECT user_id INTO v_owner FROM public.professional_services WHERE id = p_professional_service_id;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'RESTAURANT_INTROUVABLE'; END IF;
  IF v_owner = p_client_id THEN RAISE EXCEPTION 'AUTO_COMMANDE_INTERDITE'; END IF;

  PERFORM 1 FROM public.wallets WHERE user_id = v_owner AND COALESCE(is_blocked, false) = false;
  IF NOT FOUND THEN RAISE EXCEPTION 'RESTAURANT_INDISPONIBLE'; END IF;

  -- Commission sur les PLATS uniquement (pas sur les frais de livraison).
  v_rate := COALESCE(public.resolve_service_commission_rate(v_owner, 'restaurant', 15), 15);
  v_commission := round(p_amount * v_rate / 100.0);
  IF v_commission < 0 THEN v_commission := 0; END IF;
  IF v_commission > p_amount THEN v_commission := p_amount; END IF;
  v_net := p_amount - v_commission;

  -- (1) DÉBIT CLIENT = plats + frais de livraison à sa charge (0 si livraison offerte).
  v_debit := p_amount + v_client_fee;
  PERFORM public.wallet_debit_internal(p_client_id, v_debit, 'Commande restaurant', p_idempotency_key);

  -- (2) CRÉDIT RESTAURANT (net des plats).
  v_owner_res := public.credit_user_wallet_safe(v_owner, v_net, v_cur);
  v_got := COALESCE((v_owner_res->>'credited')::numeric, 0) + COALESCE((v_owner_res->>'quarantined')::numeric, 0);
  IF v_net > 0 AND v_got <= 0 THEN RAISE EXCEPTION 'CREDIT_RESTAURANT_ECHOUE'; END IF;

  INSERT INTO public.wallet_transactions (
    transaction_id, sender_user_id, receiver_user_id, amount, fee, net_amount, currency,
    transaction_type, status, description, metadata)
  VALUES (
    generate_transaction_id(), p_client_id, v_owner, p_amount, v_commission, v_net, v_cur,
    'restaurant_payment', 'completed', 'Paiement commande restaurant',
    jsonb_build_object('professional_service_id', p_professional_service_id, 'order_type', v_otype,
      'commission', v_commission, 'delivery_fee', v_fee, 'delivery_paid_by', v_fee_payer));

  -- (3) COMMISSION PDG (sur les plats) + SÉQUESTRE des frais de livraison payés par le client.
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, v_cur);
    INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id, amount, net_amount, currency, transaction_type, status, description, metadata)
    VALUES (generate_transaction_id(), NULL, v_pdg, v_commission, v_commission, v_cur, 'commission', 'completed', 'Commission restaurant',
      jsonb_build_object('professional_service_id', p_professional_service_id, 'source', 'restaurant_payment'));
  END IF;
  IF v_pdg IS NOT NULL AND v_client_fee > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_client_fee, v_cur);
    INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id, amount, net_amount, currency, transaction_type, status, description, metadata)
    VALUES (generate_transaction_id(), p_client_id, v_pdg, v_client_fee, v_client_fee, v_cur, 'commission', 'completed', 'Séquestre frais de livraison',
      jsonb_build_object('professional_service_id', p_professional_service_id, 'source', 'delivery_escrow'));
  END IF;

  -- (4) COMMANDE.
  INSERT INTO public.restaurant_orders (
    customer_user_id, professional_service_id, total, subtotal, commission, delivery_fee, delivery_fee_paid_by,
    items, order_type, table_number, delivery_address, notes, status, payment_status, payment_method, source,
    idempotency_key, order_number)
  VALUES (
    p_client_id, p_professional_service_id, p_amount, p_amount, v_commission, v_fee, v_fee_payer,
    COALESCE(p_items,'[]'::jsonb), v_otype, p_table_number, p_delivery_address, p_special_note, 'pending', 'paid', 'wallet',
    CASE WHEN p_table_number IS NOT NULL THEN 'qr_code' ELSE 'online' END,
    p_idempotency_key, lpad((floor(random()*9000)+1000)::int::text, 4, '0'))
  RETURNING id INTO v_order_id;

  UPDATE public.restaurant_orders
  SET payment_result = jsonb_build_object('success', true, 'order_id', v_order_id, 'amount_paid', v_debit,
        'restaurant_receives', v_net, 'commission', v_commission, 'delivery_fee', v_fee, 'delivery_paid_by', v_fee_payer)
  WHERE id = v_order_id;

  -- ✅ COMMISSION AGENT sur la commission plateforme (restaurant = wallet, en ligne).
  -- Le PDG a été crédité de v_commission ; credit_agent_commission en débite 20% → net 80/20.
  -- NON BLOQUANT + idempotent par order_id.
  IF v_commission > 0 THEN
    BEGIN
      PERFORM public.credit_agent_commission(p_client_id, v_commission, 'restaurant', v_order_id,
        jsonb_build_object('currency', 'GNF', 'flow', 'restaurant', 'order_id', v_order_id));
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'commission agent restaurant non appliquée (order %): %', v_order_id, SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object('success', true, 'order_id', v_order_id, 'amount_paid', v_debit,
    'restaurant_receives', v_net, 'commission', v_commission, 'delivery_fee', v_fee);
END;
$$;
REVOKE ALL ON FUNCTION public.process_restaurant_order(uuid, uuid, numeric, jsonb, text, integer, text, text, text, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_restaurant_order(uuid, uuid, numeric, jsonb, text, integer, text, text, text, numeric, text) TO service_role;

COMMIT;
