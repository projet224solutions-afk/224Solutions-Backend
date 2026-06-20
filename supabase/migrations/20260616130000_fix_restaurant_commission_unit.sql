-- ============================================================================
-- FIX CRITIQUE — UNITÉ DE COMMISSION restaurant.
-- resolve_service_commission_rate renvoie un POURCENTAGE (ex. 15, 8, 5), comme
-- partout ailleurs (cf. gb_settle_to_vendor_internal : round(total * rate / 100.0)).
-- process_restaurant_order faisait `round(p_amount * v_rate)` SANS /100 ET passait
-- 0.15 comme défaut → commission = 5000 * 15 = 75000 sur une commande de 5000 (15×),
-- restaurant_receives négatif, et l'annulation plantait (INVALID_AMOUNT).
-- Correctif : défaut 15 (pourcentage) + division par 100. Reste du corps inchangé.
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
  v_cur         text := 'GNF';
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) < 8 THEN RAISE EXCEPTION 'IDEMPOTENCY_REQUISE'; END IF;

  -- Normalise les 3 modes du spec vers l'enum existant (delivery/dine_in/takeaway).
  v_otype := CASE p_order_type WHEN 'pickup' THEN 'takeaway' WHEN 'table' THEN 'dine_in' ELSE p_order_type END;
  IF v_otype NOT IN ('delivery','dine_in','takeaway') THEN RAISE EXCEPTION 'TYPE_INVALIDE'; END IF;

  -- Idempotence : commande déjà payée pour cette clé → on renvoie son résultat (zéro double-débit).
  SELECT * INTO v_existing FROM public.restaurant_orders WHERE idempotency_key = p_idempotency_key LIMIT 1;
  IF FOUND THEN
    RETURN COALESCE(v_existing.payment_result, jsonb_build_object('success', true, 'order_id', v_existing.id, 'idempotent', true));
  END IF;

  -- Restaurateur (propriétaire du wallet crédité).
  SELECT user_id INTO v_owner FROM public.professional_services WHERE id = p_professional_service_id;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'RESTAURANT_INTROUVABLE'; END IF;
  IF v_owner = p_client_id THEN RAISE EXCEPTION 'AUTO_COMMANDE_INTERDITE'; END IF;

  -- Commission selon l'abonnement du restaurant (défaut 15 %). RATE EST UN POURCENTAGE → /100.
  v_rate := COALESCE(public.resolve_service_commission_rate(v_owner, 'restaurant', 15), 15);
  v_commission := round(p_amount * v_rate / 100.0);
  IF v_commission < 0 THEN v_commission := 0; END IF;
  IF v_commission > p_amount THEN v_commission := p_amount; END IF;
  v_net := p_amount - v_commission;

  -- (1) DÉBIT CLIENT — atomique (FOR UPDATE + vérif solde + ledger + idempotence). Lève si insuffisant.
  PERFORM public.wallet_debit_internal(p_client_id, p_amount, 'Commande restaurant', p_idempotency_key);

  -- (2) CRÉDIT RESTAURANT (net) via primitive sûre (FX/AML/cap) + ligne d'historique.
  v_owner_res := public.credit_user_wallet_safe(v_owner, v_net, v_cur);
  INSERT INTO public.wallet_transactions (
    transaction_id, sender_user_id, receiver_user_id, amount, fee, net_amount, currency,
    transaction_type, status, description, metadata)
  VALUES (
    generate_transaction_id(), p_client_id, v_owner, p_amount, v_commission, v_net, v_cur,
    'restaurant_payment', 'completed', 'Paiement commande restaurant',
    jsonb_build_object('professional_service_id', p_professional_service_id, 'order_type', v_otype,
      'commission', v_commission, 'credited', (v_owner_res->>'credited')::numeric,
      'credited_currency', v_owner_res->>'currency'));

  -- (3) COMMISSION PDG + ligne d'historique.
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

  -- (4) CRÉATION DE LA COMMANDE (payée, en attente d'acceptation par le restaurant).
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
-- NETTOYAGE de la commande de TEST polluée (commission 75000 sur 5000) : on rembourse
-- le client et on reprend au PDG le trop-perçu, via les primitives durcies (idempotent).
-- ----------------------------------------------------------------------------
DO $cleanup$
DECLARE
  o public.restaurant_orders;
  v_pdg uuid;
BEGIN
  FOR o IN
    SELECT * FROM public.restaurant_orders
    WHERE payment_status = 'paid' AND status <> 'cancelled'
      AND commission > total          -- signature du bug d'unité (commission > montant)
  LOOP
    -- Rembourser le client le montant réellement débité.
    PERFORM public.credit_user_wallet_safe(o.customer_user_id, o.total, 'GNF');
    -- Reprendre au PDG la commission COMPLÈTE qui lui avait été créditée (le restaurant, lui,
    -- n'a rien reçu : son crédit net était négatif donc ignoré par credit_user_wallet_safe).
    SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
    IF v_pdg IS NOT NULL AND o.commission > 0 THEN
      PERFORM public.wallet_debit_internal(v_pdg, o.commission,
        'Correction commission test restaurant', 'fix_resto_unit:'||o.id::text||':pdg');
    END IF;
    UPDATE public.restaurant_orders
      SET status = 'cancelled', payment_status = 'refunded', cancelled_at = now()
      WHERE id = o.id;
  END LOOP;
END
$cleanup$;

SELECT 'Fix : commission restaurant en pourcentage (/100) + défaut 15 + nettoyage commandes test polluées.' AS status;
