-- ============================================================================
-- PAIEMENT DE LA LIVRAISON RESTAURANT (modèle Uber Eats / Meituan).
--
-- Règle : le CLIENT paie les frais de livraison (en plus des plats) ; la plateforme
-- les met en SÉQUESTRE puis les reverse au LIVREUR à la livraison confirmée (98,5 %,
-- 1,5 % de marge plateforme). Le restaurant ne paie pas la livraison — SAUF s'il l'offre
-- (« livraison offerte ») : il l'absorbe alors et le livreur est payé depuis sa part.
--
-- Flux d'argent (paid_by='client') :
--   Client −(plats+frais) | Resto +net(plats) | PDG +commission(plats) +frais(séquestre)
--   → à la livraison : PDG −earning, Livreur +earning (earning = frais×0,985)
-- Flux « offerte » (paid_by='restaurant') :
--   Client −plats | Resto +net | PDG +commission
--   → à la livraison : Resto −frais, Livreur +earning, PDG +(frais−earning)
-- ============================================================================

-- 1) Colonnes : frais portés par la commande + qui les paie + drapeau de versement livreur.
ALTER TABLE public.restaurant_orders
  ADD COLUMN IF NOT EXISTS delivery_fee numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS delivery_fee_paid_by text NOT NULL DEFAULT 'client';
ALTER TABLE public.deliveries
  ADD COLUMN IF NOT EXISTS driver_paid_at timestamptz;  -- versement livreur effectué (idempotence)

-- 2) process_restaurant_order — ajout des frais de livraison (rétro-compatible : défauts 0/'client').
DROP FUNCTION IF EXISTS public.process_restaurant_order(uuid, uuid, numeric, jsonb, text, integer, text, text, text);
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

  RETURN jsonb_build_object('success', true, 'order_id', v_order_id, 'amount_paid', v_debit,
    'restaurant_receives', v_net, 'commission', v_commission, 'delivery_fee', v_fee);
END;
$$;
REVOKE ALL ON FUNCTION public.process_restaurant_order(uuid, uuid, numeric, jsonb, text, integer, text, text, text, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_restaurant_order(uuid, uuid, numeric, jsonb, text, integer, text, text, text, numeric, text) TO service_role;

-- 3) VERSEMENT LIVREUR — à la livraison confirmée, atomique et idempotent.
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

  v_earning := round(o.delivery_fee * 0.985);   -- 98,5 % au livreur
  v_margin  := o.delivery_fee - v_earning;       -- 1,5 % marge plateforme
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  IF o.delivery_fee_paid_by = 'restaurant' THEN
    -- Livraison offerte : le restaurant absorbe → on le débite des frais.
    SELECT user_id INTO v_owner FROM public.professional_services WHERE id = o.professional_service_id;
    PERFORM public.wallet_debit_internal(v_owner, o.delivery_fee, 'Frais de livraison (offerte)', 'resto_deliv:'||p_delivery_id::text);
    PERFORM public.credit_user_wallet_safe(d.driver_id, v_earning, v_cur);
    IF v_pdg IS NOT NULL AND v_margin > 0 THEN PERFORM public.credit_user_wallet_safe(v_pdg, v_margin, v_cur); END IF;
  ELSE
    -- Payé par le client : les frais sont en séquestre chez le PDG → on lui prélève la part livreur.
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
REVOKE ALL ON FUNCTION public.pay_restaurant_delivery(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pay_restaurant_delivery(uuid) TO authenticated, service_role;

-- 4) Déclenchement automatique : quand la course passe « delivered », on verse le livreur
--    (en plus de clore la commande restaurant). Trigger = couvre tous les chemins.
CREATE OR REPLACE FUNCTION public.sync_restaurant_order_on_delivery()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.restaurant_order_id IS NOT NULL AND NEW.status = 'delivered' AND (OLD.status IS DISTINCT FROM 'delivered') THEN
    UPDATE public.restaurant_orders
    SET status = 'completed', completed_at = COALESCE(completed_at, now()), updated_at = now()
    WHERE id = NEW.restaurant_order_id AND status NOT IN ('completed', 'cancelled');
    -- Versement livreur (idempotent ; n'échoue jamais la livraison).
    BEGIN
      PERFORM public.pay_restaurant_delivery(NEW.id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'pay_restaurant_delivery %: %', NEW.id, SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$$;

SELECT 'Paiement livraison restaurant : frais client→séquestre→livreur (98,5%), option offerte (resto absorbe), versement auto à la livraison.' AS status;
