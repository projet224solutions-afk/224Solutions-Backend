-- ============================================================================
-- DURCISSEMENT ATOMIQUE — process_restaurant_order.
-- Trou découvert au test : si le wallet du restaurant est BLOQUÉ (ou si le crédit
-- retombe à 0, ex. FX), l'ancienne version débitait quand même le client + créditait
-- la commission PDG, mais le restaurant recevait 0 ET la fonction renvoyait succès →
-- argent du client perdu, état incohérent. Correctif : tout-ou-rien.
--   (a) GARDE en amont : si le restaurant n'a pas de wallet créditable (absent/bloqué),
--       on REFUSE l'ordre AVANT tout débit (le client n'est jamais débité).
--   (b) ASSERTION après crédit : si le restaurant n'a effectivement rien reçu
--       (credited+quarantined = 0 alors que net > 0), on lève → rollback total.
-- Le reste du corps est identique à 20260616130000.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.process_restaurant_order(
  p_client_id               uuid,
  p_professional_service_id uuid,
  p_amount                  numeric,
  p_items                   jsonb,
  p_order_type              text,
  p_table_number            integer,
  p_delivery_address        text,
  p_special_note            text,
  p_idempotency_key         text
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
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) < 8 THEN RAISE EXCEPTION 'IDEMPOTENCY_REQUISE'; END IF;

  v_otype := CASE p_order_type WHEN 'pickup' THEN 'takeaway' WHEN 'table' THEN 'dine_in' ELSE p_order_type END;
  IF v_otype NOT IN ('delivery','dine_in','takeaway') THEN RAISE EXCEPTION 'TYPE_INVALIDE'; END IF;

  SELECT * INTO v_existing FROM public.restaurant_orders WHERE idempotency_key = p_idempotency_key LIMIT 1;
  IF FOUND THEN
    RETURN COALESCE(v_existing.payment_result, jsonb_build_object('success', true, 'order_id', v_existing.id, 'idempotent', true));
  END IF;

  SELECT user_id INTO v_owner FROM public.professional_services WHERE id = p_professional_service_id;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'RESTAURANT_INTROUVABLE'; END IF;
  IF v_owner = p_client_id THEN RAISE EXCEPTION 'AUTO_COMMANDE_INTERDITE'; END IF;

  -- (a) GARDE ATOMIQUE : le restaurant doit avoir un wallet créditable (présent + non bloqué),
  --     sinon on refuse AVANT tout débit du client.
  PERFORM 1 FROM public.wallets WHERE user_id = v_owner AND COALESCE(is_blocked, false) = false;
  IF NOT FOUND THEN RAISE EXCEPTION 'RESTAURANT_INDISPONIBLE'; END IF;

  -- Commission selon l'abonnement (défaut 15 %). RATE EST UN POURCENTAGE → /100.
  v_rate := COALESCE(public.resolve_service_commission_rate(v_owner, 'restaurant', 15), 15);
  v_commission := round(p_amount * v_rate / 100.0);
  IF v_commission < 0 THEN v_commission := 0; END IF;
  IF v_commission > p_amount THEN v_commission := p_amount; END IF;
  v_net := p_amount - v_commission;

  -- (1) DÉBIT CLIENT — atomique.
  PERFORM public.wallet_debit_internal(p_client_id, p_amount, 'Commande restaurant', p_idempotency_key);

  -- (2) CRÉDIT RESTAURANT (net) via primitive sûre (FX/AML/cap).
  v_owner_res := public.credit_user_wallet_safe(v_owner, v_net, v_cur);

  -- (b) ASSERTION : le restaurant a effectivement reçu quelque chose (sinon rollback total).
  v_got := COALESCE((v_owner_res->>'credited')::numeric, 0) + COALESCE((v_owner_res->>'quarantined')::numeric, 0);
  IF v_net > 0 AND v_got <= 0 THEN
    RAISE EXCEPTION 'CREDIT_RESTAURANT_ECHOUE';
  END IF;

  INSERT INTO public.wallet_transactions (
    transaction_id, sender_user_id, receiver_user_id, amount, fee, net_amount, currency,
    transaction_type, status, description, metadata)
  VALUES (
    generate_transaction_id(), p_client_id, v_owner, p_amount, v_commission, v_net, v_cur,
    'restaurant_payment', 'completed', 'Paiement commande restaurant',
    jsonb_build_object('professional_service_id', p_professional_service_id, 'order_type', v_otype,
      'commission', v_commission, 'credited', (v_owner_res->>'credited')::numeric,
      'credited_currency', v_owner_res->>'currency'));

  -- (3) COMMISSION PDG.
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, v_cur);
    INSERT INTO public.wallet_transactions (
      transaction_id, sender_user_id, receiver_user_id, amount, net_amount, currency,
      transaction_type, status, description, metadata)
    VALUES (
      generate_transaction_id(), NULL, v_pdg, v_commission, v_commission, v_cur,
      'commission', 'completed', 'Commission restaurant',
      jsonb_build_object('professional_service_id', p_professional_service_id, 'source', 'restaurant_payment'));
  END IF;

  -- (4) CRÉATION DE LA COMMANDE.
  INSERT INTO public.restaurant_orders (
    customer_user_id, professional_service_id, total, subtotal, commission, items, order_type,
    table_number, delivery_address, notes, status, payment_status, payment_method, source,
    idempotency_key, order_number)
  VALUES (
    p_client_id, p_professional_service_id, p_amount, p_amount, v_commission, COALESCE(p_items,'[]'::jsonb), v_otype,
    p_table_number, p_delivery_address, p_special_note, 'pending', 'paid', 'wallet',
    CASE WHEN p_table_number IS NOT NULL THEN 'qr_code' ELSE 'online' END,
    p_idempotency_key, lpad((floor(random()*9000)+1000)::int::text, 4, '0'))
  RETURNING id INTO v_order_id;

  UPDATE public.restaurant_orders
  SET payment_result = jsonb_build_object('success', true, 'order_id', v_order_id, 'amount_paid', p_amount,
        'restaurant_receives', v_net, 'commission', v_commission)
  WHERE id = v_order_id;

  RETURN jsonb_build_object('success', true, 'order_id', v_order_id, 'amount_paid', p_amount,
    'restaurant_receives', v_net, 'commission', v_commission);
END;
$$;

REVOKE ALL ON FUNCTION public.process_restaurant_order(uuid, uuid, numeric, jsonb, text, integer, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_restaurant_order(uuid, uuid, numeric, jsonb, text, integer, text, text, text) TO service_role;

-- ----------------------------------------------------------------------------
-- NETTOYAGE : commandes payées dont le restaurant a un wallet BLOQUÉ (il n'a donc
-- jamais reçu les fonds) → rembourser le client + reprendre au PDG sa commission.
-- ----------------------------------------------------------------------------
DO $cleanup$
DECLARE o public.restaurant_orders; v_pdg uuid; v_blocked boolean;
BEGIN
  FOR o IN
    SELECT ro.* FROM public.restaurant_orders ro
    WHERE ro.payment_status = 'paid' AND ro.status <> 'cancelled'
  LOOP
    SELECT COALESCE(w.is_blocked, true) INTO v_blocked
    FROM public.professional_services ps
    LEFT JOIN public.wallets w ON w.user_id = ps.user_id
    WHERE ps.id = o.professional_service_id;

    IF COALESCE(v_blocked, true) THEN
      PERFORM public.credit_user_wallet_safe(o.customer_user_id, o.total, 'GNF');
      SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
      IF v_pdg IS NOT NULL AND COALESCE(o.commission,0) > 0 THEN
        PERFORM public.wallet_debit_internal(v_pdg, o.commission,
          'Correction commande restaurant non créditée', 'fix_resto_blocked:'||o.id::text||':pdg');
      END IF;
      UPDATE public.restaurant_orders
        SET status='cancelled', payment_status='refunded', cancelled_at=now()
        WHERE id = o.id;
    END IF;
  END LOOP;
END
$cleanup$;

SELECT 'Durcissement : refus atomique si restaurant non créditable + assertion crédit + nettoyage commandes restaurant bloqué.' AS status;
