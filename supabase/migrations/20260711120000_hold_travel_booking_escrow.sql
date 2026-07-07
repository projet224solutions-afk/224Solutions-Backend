-- ════════════════════════════════════════════════════════════════════════════
-- Vol/Hôtel Phase 2 — MISE EN SÉQUESTRE d'une réservation voyage (RPC atomique).
--
-- Calquée sur hold_payment_link_escrow (version corrigée buyer_debit) — AUCUN nouveau circuit
-- d'argent : débit wallet INLINE du voyageur, commande LÉGÈRE (in_transit/paid) porteuse de
-- l'order_id (indispensable pour l'auto-release J+14 qui JOINT orders), et ligne escrow 'held'.
-- Le vendeur (agence) n'est PAS crédité ici : la libération se fait par release_escrow_to_seller
-- (confirmation client OU auto J+14), qui prélève la commission vers le coffre PDG.
--
-- Le PAIEMENT est TOUJOURS wallet pour le voyage (pas de carte ici). Idempotent : re-verrou du
-- booking + garde escrow_id IS NOT NULL.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.hold_travel_booking_escrow(
  p_booking_id       uuid,
  p_buyer_user_id    uuid,   -- voyageur (auth.users)
  p_customer_id      uuid,   -- customers.id (get-or-create par la route)
  p_vendor_id        uuid,   -- vendors.id de l'agence
  p_seller_user_id   uuid,   -- auth.users de l'agence (crédité au release)
  p_amount           numeric,-- prix CONFIRMÉ par l'agence (= travel_bookings.confirmed_amount)
  p_commission       numeric,-- commission plateforme (prélevée au release)
  p_currency         text,
  p_auto_release_days int DEFAULT 14
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking      public.travel_bookings%ROWTYPE;
  v_buyer_wallet public.wallets%ROWTYPE;
  v_cur          text := upper(coalesce(nullif(trim(p_currency), ''), 'GNF'));
  v_order_id     uuid;
  v_order_number text;
  v_escrow_id    uuid;
  v_tx_id        text;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'BAD_AMOUNT'; END IF;
  IF p_commission IS NULL OR p_commission < 0 OR p_commission > p_amount THEN RAISE EXCEPTION 'BAD_FEE'; END IF;
  IF p_buyer_user_id IS NULL OR p_seller_user_id IS NULL THEN RAISE EXCEPTION 'PARTIES_REQUIRED'; END IF;
  IF p_customer_id IS NULL OR p_vendor_id IS NULL THEN RAISE EXCEPTION 'ORDER_PARTIES_REQUIRED'; END IF;
  IF p_buyer_user_id = p_seller_user_id THEN RAISE EXCEPTION 'OWN_BOOKING'; END IF;

  -- Verrou du booking → sérialise double-clic/rejeu.
  SELECT * INTO v_booking FROM public.travel_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_NOT_FOUND'; END IF;

  -- IDEMPOTENT : déjà payé → on renvoie l'état existant.
  IF v_booking.escrow_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'already_processed', true,
      'escrow_id', v_booking.escrow_id, 'order_id', v_booking.order_id);
  END IF;

  -- Le prix doit avoir été CONFIRMÉ par l'agence. Modèle de commission UNIFIÉ : l'agence reçoit
  -- le prix COMPLET (confirmed_amount) ; le client paie la commission EN PLUS. Donc le total payé
  -- p_amount = confirmed_amount + commission → contrôle : vendor net (p_amount - commission) = prix confirmé.
  IF v_booking.status <> 'price_confirmed' OR v_booking.confirmed_amount IS NULL THEN
    RAISE EXCEPTION 'PRICE_NOT_CONFIRMED';
  END IF;
  IF round(p_amount - p_commission, 2) <> round(v_booking.confirmed_amount, 2) THEN RAISE EXCEPTION 'AMOUNT_MISMATCH'; END IF;
  IF v_booking.user_id <> p_buyer_user_id THEN RAISE EXCEPTION 'NOT_BOOKING_OWNER'; END IF;

  -- PROTECTION : l'auto-release J+14 n'est PAS programmé au paiement — il sera armé par le
  -- backend au DÉPÔT DU BILLET (route /ticket). Tant que l'agence n'a pas livré, auto_release_at
  -- reste NULL → auto_release_escrows ne libère jamais → les fonds du client sont protégés.
  v_order_number := 'TRV-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text), 1, 5);

  -- 1) DÉBIT voyageur INLINE (verrou wallet + gardes). Séquestre : le vendeur n'est PAS crédité.
  SELECT * INTO v_buyer_wallet FROM public.wallets
    WHERE user_id = p_buyer_user_id AND currency = v_cur ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BUYER_WALLET_NOT_FOUND'; END IF;
  IF v_buyer_wallet.is_blocked THEN RAISE EXCEPTION 'WALLET_BLOCKED'; END IF;
  IF v_buyer_wallet.balance < p_amount THEN RAISE EXCEPTION 'INSUFFICIENT_FUNDS'; END IF;

  UPDATE public.wallets SET balance = balance - p_amount, updated_at = now() WHERE id = v_buyer_wallet.id;

  v_tx_id := 'TRVE-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text), 1, 6);
  -- amount = net_amount = p_amount, fee (défaut 0) → respecte valid_net_amount (net = amount - fee).
  INSERT INTO public.wallet_transactions (
    transaction_id, sender_user_id, receiver_user_id, amount, net_amount,
    transaction_type, status, currency, description, metadata)
  VALUES (
    v_tx_id, p_buyer_user_id, p_seller_user_id, p_amount, p_amount,
    'payment', 'completed', v_cur, 'Réservation voyage — Fonds bloqués en séquestre',
    jsonb_build_object('source', 'travel_booking', 'booking_id', p_booking_id, 'escrow', true, 'atomic', true));

  -- 2) COMMANDE LÉGÈRE (in_transit/paid) → porte l'order_id pour l'auto-release J+14.
  INSERT INTO public.orders (
    order_number, customer_id, vendor_id, status, payment_status, payment_method,
    subtotal, total_amount, currency, shipping_address, metadata)
  VALUES (
    v_order_number, p_customer_id, p_vendor_id, 'in_transit'::order_status, 'paid'::payment_status,
    'wallet'::payment_method, p_amount, p_amount, v_cur,
    jsonb_build_object('delivery_type', 'travel_booking'),
    jsonb_build_object('source_flow', 'travel_booking', 'booking_id', p_booking_id, 'reference', v_booking.booking_reference))
  RETURNING id INTO v_order_id;

  -- 3) LIGNE ESCROW 'held' (le vendeur touchera amount - commission au release ; commission → coffre PDG).
  INSERT INTO public.escrow_transactions (
    order_id, buyer_id, seller_id, payer_id, receiver_id, amount, currency, status,
    auto_release_at, auto_release_date, payment_method, commission_amount,
    original_amount, original_currency, buyer_debit_amount, buyer_debit_currency, metadata)
  VALUES (
    v_order_id, p_buyer_user_id, p_seller_user_id, p_buyer_user_id, p_seller_user_id, p_amount, v_cur, 'held',
    NULL, NULL, 'wallet', p_commission,   -- auto_release_at armé au dépôt du billet, pas au paiement
    p_amount, v_cur, p_amount, v_cur,
    jsonb_build_object('source', 'travel_booking', 'booking_id', p_booking_id, 'vendor_amount', p_amount - p_commission,
                       'auto_release_days', p_auto_release_days))
  RETURNING id INTO v_escrow_id;

  -- 4) Liaison + passage 'paid'.
  UPDATE public.travel_bookings
     SET escrow_id      = v_escrow_id,
         order_id       = v_order_id,
         status         = 'paid',
         payment_status = 'paid',
         payment_method = 'wallet',
         total_amount   = p_amount,
         commission_amount = p_commission,
         updated_at     = now()
   WHERE id = p_booking_id;

  RETURN jsonb_build_object('success', true, 'escrow_id', v_escrow_id, 'order_id', v_order_id,
    'order_number', v_order_number, 'transaction_id', v_tx_id, 'vendor_amount', p_amount - p_commission);
END;
$$;

REVOKE ALL ON FUNCTION public.hold_travel_booking_escrow(uuid, uuid, uuid, uuid, uuid, numeric, numeric, text, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.hold_travel_booking_escrow(uuid, uuid, uuid, uuid, uuid, numeric, numeric, text, int) FROM anon;
REVOKE ALL ON FUNCTION public.hold_travel_booking_escrow(uuid, uuid, uuid, uuid, uuid, numeric, numeric, text, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.hold_travel_booking_escrow(uuid, uuid, uuid, uuid, uuid, numeric, numeric, text, int) TO service_role;
