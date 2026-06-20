-- ============================================================================
-- 🔒 DURCISSEMENT : règlement d'un lien de paiement = VRAIMENT tout-ou-rien.
--
-- Avant, le paiement wallet faisait 3 écritures séquentielles dans la route :
--   1) settle_payment_link_atomic (argent)  2) UPDATE statut du lien  3) décrément stock.
-- Si l'une des 2 dernières échouait, l'argent bougeait mais le lien/stock restaient
-- incohérents. On replie TOUT dans le RPC : argent + journal + statut « success » +
-- décrément stock, dans UNE SEULE transaction. Idempotent (clé d'idempotence) : un
-- rejeu renvoie already_processed sans rien refaire. Signature INCHANGÉE (zéro drift).
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
  v_link             public.payment_links%ROWTYPE;
  v_item             jsonb;
  v_pid              uuid;
  v_qty              numeric;
BEGIN
  IF p_gross IS NULL OR p_gross <= 0 THEN RAISE EXCEPTION 'BAD_AMOUNT'; END IF;
  IF p_fee IS NULL OR p_fee < 0 OR p_fee > p_gross THEN RAISE EXCEPTION 'BAD_FEE'; END IF;
  IF p_buyer_id = p_seller_id THEN RAISE EXCEPTION 'OWN_LINK'; END IF;
  v_net := p_gross - p_fee;

  -- IDEMPOTENCE (insert-first = verrou). Doublon/rejeu → on ne re-règle PAS.
  -- (Rollback de toute la transaction = la clé est aussi annulée → un vrai rejeu peut réussir.)
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

  INSERT INTO public.wallet_transactions (
    transaction_id, sender_user_id, receiver_user_id, amount, transaction_type, status, currency, metadata
  ) VALUES (
    v_tx_id, p_buyer_id, p_seller_id, p_gross, 'wallet', 'completed', v_cur,
    jsonb_build_object(
      'description', p_description, 'transaction_type', 'payment_link',
      'fee', p_fee, 'net_amount', v_net, 'reference', p_reference,
      'idempotency_key', p_idempotency_key, 'atomic', true
    )
  );

  -- ── DANS LA MÊME TRANSACTION : marquer le lien payé + décrémenter le stock ──
  -- p_reference = payment_id (humain) ou id (UUID en repli).
  SELECT * INTO v_link FROM public.payment_links
    WHERE payment_id = p_reference OR id::text = p_reference
    ORDER BY created_at DESC LIMIT 1 FOR UPDATE;

  IF FOUND THEN
    -- Décrément stock (idempotent via le flag metadata.stock_consumed)
    IF NOT COALESCE((v_link.metadata->>'stock_consumed')::boolean, false) THEN
      FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(v_link.metadata->'items', '[]'::jsonb)) LOOP
        v_pid := NULLIF(v_item->>'product_id', '')::uuid;
        v_qty := COALESCE((v_item->>'qty')::numeric, 1);
        IF v_pid IS NOT NULL AND v_qty > 0 THEN
          UPDATE public.products
             SET stock_quantity = GREATEST(0, COALESCE(stock_quantity, 0) - v_qty), updated_at = now()
           WHERE id = v_pid;
        END IF;
      END LOOP;
    END IF;

    UPDATE public.payment_links
       SET status = 'success', paid_at = now(), payment_method = 'wallet',
           transaction_id = v_tx_id, wallet_transaction_id = v_tx_id, wallet_credit_status = 'credited',
           gross_amount = p_gross, net_amount = v_net, platform_fee = p_fee,
           use_count = COALESCE(use_count, 0) + 1,
           metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('stock_consumed', true),
           updated_at = now()
     WHERE id = v_link.id;
  END IF;

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id, 'net_amount', v_net, 'fee', p_fee);
END;
$$;

REVOKE ALL ON FUNCTION public.settle_payment_link_atomic(uuid, uuid, numeric, numeric, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.settle_payment_link_atomic(uuid, uuid, numeric, numeric, text, text, text, text) TO service_role;

SELECT 'settle_payment_link_atomic renforcé : argent + statut lien + stock dans UNE transaction (idempotent).' AS status;
