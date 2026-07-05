-- ============================================================================
-- 🔐 LIEN DE PAIEMENT EN ESCROW (5ᵉ type `escrow`) — séquestre à la réception
-- ----------------------------------------------------------------------------
-- Un lien de paiement de type `escrow` met l'argent EN SÉQUESTRE au lieu de créditer
-- immédiatement le vendeur. Le vendeur n'est crédité qu'après que l'ACHETEUR (compte
-- obligatoire) confirme la réception depuis « Mes Achats ».
--
-- SCHÉMA lien ↔ escrow ↔ commande retenu :
--   escrow_transactions.order_id est NOT NULL référençant orders(id). On génère donc une
--   COMMANDE LÉGÈRE (préfixe ESC-) qui PORTE l'order_id : customer_id = acheteur (→ apparaît
--   dans GET /api/orders/mine → « Mes Achats »), vendor_id = vendeur du lien, status
--   'in_transit' (⇒ le bouton « J'ai reçu ma commande » s'affiche ET l'auto-libération 14 j
--   via auto_release_escrows() s'applique — elle exige o.status IN ('delivered','in_transit')).
--   L'escrow est ensuite lié au lien via payment_links.escrow_id.
--
-- SÉQUESTRE RÉEL : le wallet DISPONIBLE du vendeur n'est JAMAIS crédité à ce stade.
--   • Wallet   : l'acheteur est débité du montant, aucun crédit vendeur (comme create_order_core).
--   • Carte    : l'argent est encaissé côté Stripe (plateforme), aucun crédit vendeur.
--   La libération (crédit vendeur net + commission PDG) passe UNIQUEMENT par la primitive
--   canonique release_escrow_to_seller() à la confirmation de réception (ou à J+14).
--
-- ATOMIQUE + IDEMPOTENT : tout se fait dans UNE transaction ; le verrou FOR UPDATE sur le lien
--   + le garde `payment_links.escrow_id IS NOT NULL` empêchent un rejeu (webhook Stripe /
--   double-clic) de créer 2 escrows / 2 commandes.
-- ============================================================================

-- 1) ── Étendre la contrainte CHECK du type de lien pour accepter 'escrow' ────
ALTER TABLE public.payment_links DROP CONSTRAINT IF EXISTS chk_link_type;
ALTER TABLE public.payment_links
  ADD CONSTRAINT chk_link_type CHECK (link_type IN ('payment', 'invoice', 'checkout', 'service', 'escrow'));

-- 2) ── Colonne de liaison lien → escrow ─────────────────────────────────────
ALTER TABLE public.payment_links
  ADD COLUMN IF NOT EXISTS escrow_id UUID REFERENCES public.escrow_transactions(id);

CREATE INDEX IF NOT EXISTS idx_payment_links_escrow_id ON public.payment_links(escrow_id);

-- 3) ── RPC atomique : encaisser un lien escrow → commande légère + escrow HELD ─
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
  INSERT INTO public.escrow_transactions (
    order_id, buyer_id, seller_id, payer_id, receiver_id, amount, currency, status,
    auto_release_at, auto_release_date, payment_method, commission_amount,
    original_amount, original_currency, metadata)
  VALUES (
    v_order_id, p_buyer_user_id, p_seller_user_id, p_buyer_user_id, p_seller_user_id, p_amount, v_cur, 'held',
    v_release_at, v_release_at, p_payment_method, p_commission,
    p_amount, v_cur,
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

SELECT 'Lien escrow : chk_link_type + payment_links.escrow_id + hold_payment_link_escrow (atomique, idempotent, séquestre réel).' AS status;
