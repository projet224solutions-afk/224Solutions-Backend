-- ============================================================================
-- SERVICE RESTAURANT — PAIEMENT ATOMIQUE (Phase 1). ADDITIF sur l'existant.
-- ----------------------------------------------------------------------------
-- La table restaurant_orders existe déjà (clé professional_service_id + customer_user_id).
-- On AJOUTE les colonnes de paiement et 2 RPC atomiques composées avec les PRIMITIVES
-- DURCIES (wallet_debit_internal, credit_user_wallet_safe, resolve_service_commission_rate) —
-- JAMAIS d'UPDATE wallets brut (qui contournerait AML/FX/audit). Tout-ou-rien + idempotence.
-- Devise : base GNF (prix restaurant en GNF). FX client cross-devise = Phase 2 (pré-conversion backend).
-- ============================================================================

-- 1) Colonnes de paiement (additif, idempotent).
ALTER TABLE public.restaurant_orders
  ADD COLUMN IF NOT EXISTS commission            numeric(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS idempotency_key       text,
  ADD COLUMN IF NOT EXISTS payment_result        jsonb,
  ADD COLUMN IF NOT EXISTS estimated_prep_minutes integer,
  ADD COLUMN IF NOT EXISTS accepted_at           timestamptz,
  ADD COLUMN IF NOT EXISTS cancelled_at          timestamptz;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_restaurant_orders_idem
  ON public.restaurant_orders (idempotency_key) WHERE idempotency_key IS NOT NULL;

-- 2) PAIEMENT ATOMIQUE : débit client → crédit restaurant (net) → commission PDG → commande.
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

  -- Commission selon l'abonnement du restaurant (défaut 15 %).
  v_rate := COALESCE(public.resolve_service_commission_rate(v_owner, 'restaurant', 0.15), 0.15);
  v_commission := round(p_amount * v_rate);
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

-- 3) ANNULATION ATOMIQUE + REMBOURSEMENT (auto 3 min OU refus restaurant).
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
BEGIN
  SELECT * INTO v_o FROM public.restaurant_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMMANDE_INTROUVABLE'; END IF;
  IF v_o.payment_status = 'refunded' OR v_o.status = 'cancelled' THEN
    RETURN jsonb_build_object('success', true, 'already_refunded', true);
  END IF;
  IF v_o.status NOT IN ('pending','accepted','confirmed') THEN RAISE EXCEPTION 'ANNULATION_IMPOSSIBLE'; END IF;

  v_key := 'resto_refund:' || p_order_id::text;

  -- Rembourser le client (priorité) + ligne d'historique.
  PERFORM public.credit_user_wallet_safe(v_o.customer_user_id, v_o.total, 'GNF');
  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_user_id, amount, net_amount, currency, transaction_type, status, description, metadata)
  VALUES (
    generate_transaction_id(), v_o.customer_user_id, v_o.total, v_o.total, 'GNF',
    'refund', 'completed', 'Remboursement commande restaurant annulée',
    jsonb_build_object('order_id', p_order_id, 'reason', p_reason));

  -- Reprendre au restaurant (net) et au PDG (commission) ce qui avait été crédité (double-entrée).
  IF v_o.payment_status = 'paid' THEN
    SELECT user_id INTO v_owner FROM public.professional_services WHERE id = v_o.professional_service_id;
    IF v_owner IS NOT NULL THEN
      PERFORM public.wallet_debit_internal(v_owner, v_o.total - COALESCE(v_o.commission,0), 'Annulation commande restaurant', v_key||':owner');
    END IF;
    SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
    IF v_pdg IS NOT NULL AND COALESCE(v_o.commission,0) > 0 THEN
      PERFORM public.wallet_debit_internal(v_pdg, v_o.commission, 'Annulation commission restaurant', v_key||':pdg');
    END IF;
  END IF;

  UPDATE public.restaurant_orders
  SET status='cancelled', cancelled_reason=p_reason, cancelled_at=now(), payment_status='refunded', updated_at=now()
  WHERE id = p_order_id;

  RETURN jsonb_build_object('success', true, 'refunded', v_o.total);
END;
$$;

-- Sécurité : exécutables uniquement par le backend (service_role), jamais anon/authenticated.
REVOKE ALL ON FUNCTION public.process_restaurant_order(uuid,uuid,numeric,jsonb,text,integer,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_restaurant_order(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_restaurant_order(uuid,uuid,numeric,jsonb,text,integer,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.cancel_restaurant_order(uuid,text) TO service_role;

SELECT 'Restaurant : paiement atomique + annulation/remboursement (Phase 1).' AS status;
