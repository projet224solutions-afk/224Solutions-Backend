-- ============================================================================
-- 💳 RÈGLEMENT ATOMIQUE D'UN LIEN DE PAIEMENT (wallet acheteur → vendeur).
--
-- AVANT : la route /api/payment-links/process débitait l'acheteur puis créditait le
-- vendeur en DEUX écritures séparées non transactionnelles (crédit vendeur en
-- read-modify-write sans verrou) → si le crédit échouait après le débit, l'argent
-- DISPARAISSAIT ; et aucune idempotence → double-paiement possible au rejeu.
--
-- ICI : un seul RPC tout-ou-rien. Verrouille les 2 wallets (FOR UPDATE), débite le
-- montant brut à l'acheteur, crédite le NET au vendeur, la plateforme garde les frais
-- (spread, comme avant). Idempotent : la clé (UNIQUE) sert de verrou anti-rejeu.
--
-- ⚠️ Volontairement SANS enforce_transfer_limit : c'est un ACHAT, pas un transfert P2P
--    (les plafonds jour/mois ne doivent pas bloquer un paiement de lien).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.settle_payment_link_atomic(
  p_buyer_id        uuid,
  p_seller_id       uuid,
  p_gross           numeric,
  p_fee             numeric,
  p_currency        text,
  p_reference       text,
  p_idempotency_key text,
  p_description     text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_buyer_wallet     public.wallets%ROWTYPE;
  v_seller_wallet_id bigint;
  v_net              numeric;
  v_tx_id            text;
  v_cur              text := upper(coalesce(nullif(trim(p_currency), ''), 'GNF'));
BEGIN
  IF p_gross IS NULL OR p_gross <= 0 THEN RAISE EXCEPTION 'BAD_AMOUNT'; END IF;
  IF p_fee IS NULL OR p_fee < 0 OR p_fee > p_gross THEN RAISE EXCEPTION 'BAD_FEE'; END IF;
  IF p_buyer_id = p_seller_id THEN RAISE EXCEPTION 'OWN_LINK'; END IF;
  v_net := p_gross - p_fee;

  -- IDEMPOTENCE (insert-first = verrou). Doublon/rejeu → on ne re-règle PAS.
  BEGIN
    INSERT INTO public.wallet_idempotency_keys (idempotency_key, user_id, operation)
    VALUES (p_idempotency_key, p_buyer_id, 'payment_link');
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('success', true, 'already_processed', true);
  END;

  -- Verrou acheteur
  SELECT * INTO v_buyer_wallet
  FROM public.wallets WHERE user_id = p_buyer_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BUYER_WALLET_NOT_FOUND'; END IF;
  IF v_buyer_wallet.is_blocked THEN RAISE EXCEPTION 'WALLET_BLOCKED'; END IF;
  IF v_buyer_wallet.balance < p_gross THEN RAISE EXCEPTION 'INSUFFICIENT_FUNDS'; END IF;

  -- Verrou vendeur
  SELECT id INTO v_seller_wallet_id
  FROM public.wallets WHERE user_id = p_seller_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF v_seller_wallet_id IS NULL THEN RAISE EXCEPTION 'SELLER_WALLET_NOT_FOUND'; END IF;

  -- Mouvements ATOMIQUES : débit acheteur (brut) + crédit vendeur (net).
  UPDATE public.wallets SET balance = balance - p_gross, updated_at = now() WHERE id = v_buyer_wallet.id;
  UPDATE public.wallets SET balance = balance + v_net,  updated_at = now() WHERE id = v_seller_wallet_id;

  v_tx_id := 'PLK-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text), 1, 6);

  -- Journal (calqué sur execute_atomic_wallet_transfer : colonne transaction_type='wallet',
  -- sémantique réelle dans metadata).
  INSERT INTO public.wallet_transactions (
    transaction_id, sender_user_id, receiver_user_id, amount, transaction_type, status, currency, metadata
  ) VALUES (
    v_tx_id, p_buyer_id, p_seller_id, p_gross, 'wallet', 'completed', v_cur,
    jsonb_build_object(
      'description', p_description,
      'transaction_type', 'payment_link',
      'fee', p_fee,
      'net_amount', v_net,
      'reference', p_reference,
      'idempotency_key', p_idempotency_key,
      'atomic', true
    )
  );

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id, 'net_amount', v_net, 'fee', p_fee);
END;
$$;

-- Privilégiée : backend (service_role) uniquement. Jamais anon.
REVOKE ALL ON FUNCTION public.settle_payment_link_atomic(uuid, uuid, numeric, numeric, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.settle_payment_link_atomic(uuid, uuid, numeric, numeric, text, text, text, text) TO service_role;

SELECT 'RPC settle_payment_link_atomic créé (règlement lien atomique + idempotent, sans plafond P2P).' AS status;
