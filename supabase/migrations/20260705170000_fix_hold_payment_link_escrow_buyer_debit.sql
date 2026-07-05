-- ============================================================================
-- 🛠️ CORRECTIF CRITIQUE : hold_payment_link_escrow doit ENREGISTRER buyer_debit_amount
-- ----------------------------------------------------------------------------
-- BUG (audit 2026-07-05) : pour un lien escrow payé au WALLET, la RPC débitait bien
-- l'acheteur de p_amount, mais l'INSERT dans escrow_transactions N'ÉCRIVAIT PAS
-- buyer_debit_amount / buyer_debit_currency. Or refund_order_escrow
-- (20260702260000) calcule v_refund_amount := COALESCE(buyer_debit_amount, 0) → 0 :
-- sur litige/annulation, l'escrow passait 'refunded' SANS recréditer l'acheteur
-- (perte sèche pour le client).
--
-- FIX : cette migration recrée hold_payment_link_escrow À L'IDENTIQUE de
-- 20260705100000 SAUF l'INSERT escrow qui écrit désormais :
--   buyer_debit_amount   = CASE WHEN p_debit_wallet THEN p_amount ELSE NULL END
--   buyer_debit_currency = CASE WHEN p_debit_wallet THEN v_cur   ELSE NULL END
-- (aligné sur create_order_core). NULL en carte reste correct (remboursement via Stripe).
-- Idempotent (CREATE OR REPLACE). Grants inchangés (service_role uniquement).
-- ============================================================================

-- Défensif : garantir la présence des colonnes (déjà ajoutées en 20260518500000).
ALTER TABLE public.escrow_transactions
  ADD COLUMN IF NOT EXISTS buyer_debit_amount   NUMERIC(20, 4),
  ADD COLUMN IF NOT EXISTS buyer_debit_currency VARCHAR(3);

CREATE OR REPLACE FUNCTION public.hold_payment_link_escrow(
  p_link_id           uuid,
  p_buyer_user_id     uuid,
  p_customer_id       uuid,
  p_vendor_id         uuid,
  p_seller_user_id    uuid,
  p_amount            numeric,
  p_commission        numeric,
  p_currency          text,
  p_payment_method    text,
  p_payment_reference text,     -- ex : PaymentIntent Stripe (carte)
  p_debit_wallet      boolean,  -- true UNIQUEMENT pour un paiement wallet
  p_auto_release_days int DEFAULT 14
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_link          public.payment_links%ROWTYPE;
  v_buyer_wallet  public.wallets%ROWTYPE;
  v_cur           text := upper(coalesce(nullif(trim(p_currency), ''), 'GNF'));
  v_net           numeric;
  v_release_at    timestamptz;
  v_order_id      uuid;
  v_order_number  text;
  v_escrow_id     uuid;
  v_tx_id         text := NULL;
BEGIN
  -- Garde-fous montants / identités
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'BAD_AMOUNT'; END IF;
  IF p_commission IS NULL OR p_commission < 0 OR p_commission > p_amount THEN RAISE EXCEPTION 'BAD_FEE'; END IF;
  IF p_buyer_user_id IS NULL THEN RAISE EXCEPTION 'BUYER_REQUIRED'; END IF;   -- compte obligatoire (serveur)
  IF p_seller_user_id IS NULL THEN RAISE EXCEPTION 'SELLER_REQUIRED'; END IF;
  IF p_vendor_id IS NULL THEN RAISE EXCEPTION 'VENDOR_REQUIRED'; END IF;
  IF p_customer_id IS NULL THEN RAISE EXCEPTION 'CUSTOMER_REQUIRED'; END IF;
  IF p_buyer_user_id = p_seller_user_id THEN RAISE EXCEPTION 'OWN_LINK'; END IF;

  -- Verrou du lien → sérialise les rejeux concurrents (webhook / double-clic)
  SELECT * INTO v_link FROM public.payment_links WHERE id = p_link_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'LINK_NOT_FOUND'; END IF;

  -- IDEMPOTENT : un escrow existe déjà pour ce lien → on renvoie sans rien refaire
  IF v_link.escrow_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'already_processed', true,
      'escrow_id', v_link.escrow_id, 'order_id', v_link.order_id);
  END IF;

  IF v_link.link_type <> 'escrow' THEN RAISE EXCEPTION 'NOT_ESCROW_LINK'; END IF;

  v_net          := p_amount - p_commission;
  v_release_at   := now() + (p_auto_release_days || ' days')::interval;
  v_order_number := 'ESC-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text), 1, 5);

  -- ── Débit wallet acheteur (paiement wallet UNIQUEMENT) — AUCUN crédit vendeur (séquestre) ──
  IF p_debit_wallet THEN
    SELECT * INTO v_buyer_wallet FROM public.wallets
      WHERE user_id = p_buyer_user_id AND currency = v_cur ORDER BY id LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'BUYER_WALLET_NOT_FOUND'; END IF;
    IF v_buyer_wallet.is_blocked THEN RAISE EXCEPTION 'WALLET_BLOCKED'; END IF;
    IF v_buyer_wallet.balance < p_amount THEN RAISE EXCEPTION 'INSUFFICIENT_FUNDS'; END IF;

    UPDATE public.wallets SET balance = balance - p_amount, updated_at = now() WHERE id = v_buyer_wallet.id;

    v_tx_id := 'PLKE-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text), 1, 6);
    INSERT INTO public.wallet_transactions (
      transaction_id, sender_user_id, receiver_user_id, amount, net_amount,
      transaction_type, status, currency, description, metadata)
    VALUES (
      v_tx_id, p_buyer_user_id, p_seller_user_id, p_amount, p_amount,
      'payment', 'completed', v_cur, 'Paiement lien sécurisé — Fonds bloqués en Escrow',
      jsonb_build_object('payment_link_id', p_link_id, 'escrow', true, 'atomic', true));
  END IF;

  -- ── Commande LÉGÈRE porteuse de l'order_id (apparaît dans « Mes Achats » de l'acheteur) ──
  INSERT INTO public.orders (
    order_number, customer_id, vendor_id, status, payment_status, payment_method,
    subtotal, total_amount, currency, shipping_address, metadata)
  VALUES (
    v_order_number, p_customer_id, p_vendor_id, 'in_transit'::order_status, 'paid'::payment_status,
    p_payment_method::payment_method, p_amount, p_amount, v_cur,
    jsonb_build_object('full_name', COALESCE(v_link.customer_name, 'Acheteur'), 'delivery_type', 'secure_payment'),
    jsonb_build_object('source_flow', 'escrow_payment_link', 'payment_link_id', p_link_id,
      'payment_link_token', v_link.token, 'title', v_link.title, 'reference', v_link.payment_id))
  RETURNING id INTO v_order_id;

  -- ── Escrow HELD : vendeur (receiver_id/seller_id) NON crédité ; payeur = acheteur connecté ──
  --    ✅ FIX : buyer_debit_amount/currency renseignés pour le WALLET → refund_order_escrow
  --       recrédite l'acheteur en cas de litige/annulation. NULL en carte (refund via Stripe).
  INSERT INTO public.escrow_transactions (
    order_id, buyer_id, seller_id, payer_id, receiver_id, amount, currency, status,
    auto_release_at, auto_release_date, payment_method, commission_amount,
    original_amount, original_currency, buyer_debit_amount, buyer_debit_currency, metadata)
  VALUES (
    v_order_id, p_buyer_user_id, p_seller_user_id, p_buyer_user_id, p_seller_user_id, p_amount, v_cur, 'held',
    v_release_at, v_release_at, p_payment_method, p_commission,
    p_amount, v_cur,
    CASE WHEN p_debit_wallet THEN p_amount ELSE NULL END,
    CASE WHEN p_debit_wallet THEN v_cur   ELSE NULL END,
    jsonb_build_object('source', 'escrow_payment_link', 'payment_link_id', p_link_id, 'vendor_amount', v_net))
  RETURNING id INTO v_escrow_id;

  -- ── Lier l'escrow au lien + marquer payé. wallet_credit_status='none' : vendeur NON crédité. ──
  UPDATE public.payment_links
     SET escrow_id            = v_escrow_id,
         order_id             = v_order_id,
         status               = 'success',
         paid_at              = now(),
         payment_method       = p_payment_method,
         transaction_id       = COALESCE(p_payment_reference, v_tx_id),
         wallet_transaction_id = v_tx_id,
         wallet_credit_status = 'none',
         gross_amount         = p_amount,
         net_amount           = v_net,
         platform_fee         = p_commission,
         use_count            = COALESCE(use_count, 0) + 1,
         updated_at           = now()
   WHERE id = p_link_id;

  RETURN jsonb_build_object('success', true, 'escrow_id', v_escrow_id, 'order_id', v_order_id,
    'order_number', v_order_number, 'vendor_amount', v_net, 'transaction_id', v_tx_id);
END;
$$;

-- SECURITY DEFINER sensible (mouvement d'argent) → réservé au service_role.
REVOKE ALL ON FUNCTION public.hold_payment_link_escrow(uuid, uuid, uuid, uuid, uuid, numeric, numeric, text, text, text, boolean, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hold_payment_link_escrow(uuid, uuid, uuid, uuid, uuid, numeric, numeric, text, text, text, boolean, int) TO service_role;

SELECT 'FIX escrow lien : hold_payment_link_escrow écrit buyer_debit_amount/currency (wallet) → refund_order_escrow recrédite bien l''acheteur.' AS status;
