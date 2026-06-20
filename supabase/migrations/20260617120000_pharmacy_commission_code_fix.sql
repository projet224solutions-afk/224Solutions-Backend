-- ============================================================================
-- SERVICE PHARMACIE — CORRECTIF : code de service_type pour la commission par plan.
--
-- BUG : process_pharmacy_order appelait resolve_service_commission_rate(v_owner, 'pharmacy', 15),
-- mais le service_type créé a pour code 'pharmacie'. resolve_service_commission_rate compare
-- st.code = p_service_type_code → 'pharmacy' ne matchait JAMAIS → le taux retombait toujours sur
-- 15% par défaut, ignorant les commissions dégressives des plans (15/12/8/5%).
--
-- FIX : passer 'pharmacie' (le vrai code). Aucune autre logique modifiée (CREATE OR REPLACE).
-- Idempotent.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.process_pharmacy_order(
  p_client_id        uuid,
  p_pharmacy_id      uuid,
  p_prescription_id  uuid,
  p_amount           numeric,
  p_medications      jsonb,
  p_delivery_type    text,
  p_delivery_address text,
  p_idempotency_key  text,
  p_delivery_fee     numeric DEFAULT 0,
  p_delivery_paid_by text    DEFAULT 'client'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_existing    public.pharmacy_orders;
  v_owner       uuid;
  v_pdg         uuid;
  v_rate        numeric;
  v_commission  numeric;
  v_net         numeric;
  v_order_id    uuid;
  v_owner_res   jsonb;
  v_got         numeric;
  v_cur         text := 'GNF';
  v_presc       public.prescriptions;
  v_dtype       text := CASE WHEN p_delivery_type = 'delivery' THEN 'delivery' ELSE 'pickup' END;
  v_fee         numeric := GREATEST(0, COALESCE(p_delivery_fee, 0));
  v_fee_payer   text := CASE WHEN p_delivery_paid_by = 'restaurant' THEN 'restaurant' ELSE 'client' END;
  v_client_fee  numeric;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) < 8 THEN RAISE EXCEPTION 'IDEMPOTENCY_REQUISE'; END IF;
  IF v_dtype = 'pickup' THEN v_fee := 0; END IF;
  v_client_fee := CASE WHEN v_fee_payer = 'client' THEN v_fee ELSE 0 END;

  SELECT * INTO v_existing FROM public.pharmacy_orders WHERE idempotency_key = p_idempotency_key LIMIT 1;
  IF FOUND THEN
    RETURN COALESCE(v_existing.result, jsonb_build_object('success', true, 'order_id', v_existing.id, 'idempotent', true));
  END IF;

  SELECT * INTO v_presc FROM public.prescriptions WHERE id = p_prescription_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDONNANCE_INTROUVABLE'; END IF;
  IF v_presc.status NOT IN ('validated', 'quoted') THEN RAISE EXCEPTION 'ORDONNANCE_NON_VALIDEE'; END IF;
  IF v_presc.pharmacy_id <> p_pharmacy_id OR v_presc.client_id <> p_client_id THEN RAISE EXCEPTION 'ORDONNANCE_NON_CONCORDANTE'; END IF;

  SELECT user_id INTO v_owner FROM public.professional_services WHERE id = p_pharmacy_id;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'PHARMACIE_INTROUVABLE'; END IF;
  IF v_owner = p_client_id THEN RAISE EXCEPTION 'AUTO_COMMANDE_INTERDITE'; END IF;
  PERFORM 1 FROM public.wallets WHERE user_id = v_owner AND COALESCE(is_blocked, false) = false;
  IF NOT FOUND THEN RAISE EXCEPTION 'PHARMACIE_INDISPONIBLE'; END IF;

  -- ✅ FIX : code 'pharmacie' (et non 'pharmacy') → la commission du plan actif est bien appliquée.
  v_rate := COALESCE(public.resolve_service_commission_rate(v_owner, 'pharmacie', 15), 15);
  v_commission := round(p_amount * v_rate / 100.0);
  IF v_commission < 0 THEN v_commission := 0; END IF;
  IF v_commission > p_amount THEN v_commission := p_amount; END IF;
  v_net := p_amount - v_commission;

  PERFORM public.wallet_debit_internal(p_client_id, p_amount + v_client_fee, 'Commande pharmacie', p_idempotency_key);

  v_owner_res := public.credit_user_wallet_safe(v_owner, v_net, v_cur);
  v_got := COALESCE((v_owner_res->>'credited')::numeric, 0) + COALESCE((v_owner_res->>'quarantined')::numeric, 0);
  IF v_net > 0 AND v_got <= 0 THEN RAISE EXCEPTION 'CREDIT_PHARMACIE_ECHOUE'; END IF;

  INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id, amount, fee, net_amount, currency, transaction_type, status, description, metadata)
  VALUES (generate_transaction_id(), p_client_id, v_owner, p_amount, v_commission, v_net, v_cur, 'payment', 'completed', 'Paiement commande pharmacie',
    jsonb_build_object('pharmacy_id', p_pharmacy_id, 'prescription_id', p_prescription_id, 'commission', v_commission, 'delivery_fee', v_fee, 'kind', 'pharmacy_payment'));

  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, v_cur);
    INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id, amount, net_amount, currency, transaction_type, status, description, metadata)
    VALUES (generate_transaction_id(), NULL, v_pdg, v_commission, v_commission, v_cur, 'commission', 'completed', 'Commission pharmacie',
      jsonb_build_object('pharmacy_id', p_pharmacy_id, 'source', 'pharmacy_payment'));
  END IF;
  IF v_pdg IS NOT NULL AND v_client_fee > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_client_fee, v_cur);
    INSERT INTO public.wallet_transactions (transaction_id, sender_user_id, receiver_user_id, amount, net_amount, currency, transaction_type, status, description, metadata)
    VALUES (generate_transaction_id(), p_client_id, v_pdg, v_client_fee, v_client_fee, v_cur, 'commission', 'completed', 'Séquestre frais de livraison pharmacie',
      jsonb_build_object('pharmacy_id', p_pharmacy_id, 'source', 'delivery_escrow'));
  END IF;

  INSERT INTO public.pharmacy_orders (
    client_id, pharmacy_id, prescription_id, amount, commission, delivery_fee, delivery_fee_paid_by,
    medications, delivery_type, delivery_address, status, payment_status, idempotency_key)
  VALUES (
    p_client_id, p_pharmacy_id, p_prescription_id, p_amount, v_commission, v_fee, v_fee_payer,
    COALESCE(p_medications, '[]'::jsonb), v_dtype, p_delivery_address, 'preparing', 'paid', p_idempotency_key)
  RETURNING id INTO v_order_id;

  UPDATE public.pharmacy_orders SET result = jsonb_build_object('success', true, 'order_id', v_order_id, 'amount_paid', p_amount + v_client_fee, 'pharmacy_receives', v_net, 'commission', v_commission)
  WHERE id = v_order_id;

  RETURN jsonb_build_object('success', true, 'order_id', v_order_id, 'amount_paid', p_amount + v_client_fee, 'pharmacy_receives', v_net, 'commission', v_commission);
END;
$$;

REVOKE ALL ON FUNCTION public.process_pharmacy_order(uuid, uuid, uuid, numeric, jsonb, text, text, text, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_pharmacy_order(uuid, uuid, uuid, numeric, jsonb, text, text, text, numeric, text) TO service_role;

SELECT 'Pharmacie : commission par plan corrigée (code service_type pharmacie).' AS status;
