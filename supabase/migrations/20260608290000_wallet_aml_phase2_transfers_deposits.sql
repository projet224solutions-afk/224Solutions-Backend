-- ============================================================================
-- AML — PHASE 2 : plafond + quarantaine sur TRANSFERTS & DÉPÔTS
-- ----------------------------------------------------------------------------
-- Phase 1 : auto-quarantaine seulement dans credit_user_wallet_safe (escrow/
-- remboursement/commission). Phase 2 : on étend l'auto-quarantaine aux deux
-- autres primitives money-in :
--   • transferts P2P : execute_atomic_wallet_transfer + _fx (crédit destinataire),
--   • dépôts / crédits admin : via credit_user_wallet_safe (le backend Node y est rebranché).
--
-- Pour éviter toute duplication, la logique « plafond → excédent en quarantaine »
-- est factorisée dans UN helper SECURITY DEFINER : apply_wallet_cap_split(). Il prend
-- le solde courant (déjà verrouillé par l'appelant), calcule le dépassement en GNF,
-- met l'excédent en quarantaine (devise du wallet, proportionnel) et RENVOIE le
-- montant réellement créditable. credit_user_wallet_safe + les 2 RPC transfert
-- l'utilisent → une seule source de vérité. Non destructif, rejouable.
-- ============================================================================

-- ───────────── Helper unique : calcule l'excédent, le met en quarantaine, renvoie le créditable ─────────────
CREATE OR REPLACE FUNCTION public.apply_wallet_cap_split(
  p_user_id         uuid,
  p_wallet_id       bigint,
  p_current_balance numeric,
  p_credit          numeric,
  p_currency        text,
  p_source_type     text DEFAULT NULL,
  p_source_txn_id   text DEFAULT NULL
)
RETURNS numeric   -- montant réellement à créditer (le reste est mis en quarantaine)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cap_gnf    numeric;
  v_bal_gnf    numeric;
  v_credit_gnf numeric;
  v_over_gnf   numeric;
  v_q_frac     numeric;
  v_q_amt      numeric;
BEGIN
  IF p_credit IS NULL OR p_credit <= 0 THEN RETURN COALESCE(p_credit, 0); END IF;

  v_cap_gnf := public.wallet_effective_cap(p_user_id);     -- NULL = illimité / exempté
  IF v_cap_gnf IS NULL THEN RETURN p_credit; END IF;

  v_bal_gnf    := public.convert_to_gnf(COALESCE(p_current_balance, 0), p_currency);
  v_credit_gnf := public.convert_to_gnf(p_credit, p_currency);
  v_over_gnf   := (v_bal_gnf + v_credit_gnf) - v_cap_gnf;

  IF v_over_gnf <= 0 OR v_credit_gnf <= 0 THEN RETURN p_credit; END IF;

  v_q_frac := LEAST(v_over_gnf / v_credit_gnf, 1.0);
  v_q_amt  := ROUND(p_credit * v_q_frac, 2);

  INSERT INTO public.wallet_quarantined_funds (
    user_id, wallet_id, amount, currency, source_transaction_id, source_type, reason, status)
  VALUES (
    p_user_id, p_wallet_id, v_q_amt, p_currency, p_source_txn_id, p_source_type, 'cap_exceeded', 'pending');

  RETURN p_credit - v_q_amt;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_wallet_cap_split(uuid, bigint, numeric, numeric, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_wallet_cap_split(uuid, bigint, numeric, numeric, text, text, text) TO authenticated, service_role;

-- ───────────── credit_user_wallet_safe : utilise désormais le helper (source unique) ─────────────
DROP FUNCTION IF EXISTS public.credit_user_wallet_safe(uuid, numeric, text);
CREATE OR REPLACE FUNCTION public.credit_user_wallet_safe(
  p_user_id       uuid,
  p_amount        numeric,
  p_from_currency text DEFAULT NULL,
  p_source_type   text DEFAULT NULL,
  p_source_txn_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id  bigint;
  v_wallet_cur text;
  v_bal        numeric;
  v_rate       numeric;
  v_credit     numeric;
  v_credited   numeric;
  v_q_amt      numeric := 0;
BEGIN
  IF p_user_id IS NULL OR COALESCE(p_amount, 0) <= 0 THEN
    RETURN jsonb_build_object('credited', 0, 'currency', p_from_currency, 'skipped', true);
  END IF;

  SELECT id, currency, balance INTO v_wallet_id, v_wallet_cur, v_bal
  FROM public.wallets
  WHERE user_id = p_user_id
  ORDER BY (currency = p_from_currency) DESC, id ASC
  LIMIT 1 FOR UPDATE;

  IF v_wallet_id IS NULL THEN
    INSERT INTO public.wallets (user_id, balance, currency, wallet_status)
    VALUES (p_user_id, 0, COALESCE(p_from_currency, 'GNF'), 'active')
    RETURNING id, currency, balance INTO v_wallet_id, v_wallet_cur, v_bal;
  END IF;

  -- Conversion vers la devise du wallet.
  IF p_from_currency IS NULL OR v_wallet_cur = p_from_currency THEN
    v_credit := p_amount;
  ELSE
    SELECT CASE WHEN cer.from_currency = p_from_currency THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END
    INTO v_rate
    FROM public.currency_exchange_rates cer
    WHERE ((cer.from_currency = p_from_currency AND cer.to_currency = v_wallet_cur)
        OR (cer.from_currency = v_wallet_cur AND cer.to_currency = p_from_currency))
      AND cer.is_active = true
    ORDER BY cer.retrieved_at DESC LIMIT 1;
    v_credit := ROUND(p_amount * COALESCE(v_rate, 1.0), 2);
  END IF;

  -- Plafond + quarantaine via le helper unique.
  v_credited := public.apply_wallet_cap_split(p_user_id, v_wallet_id, COALESCE(v_bal, 0), v_credit, v_wallet_cur, p_source_type, p_source_txn_id);
  v_q_amt    := v_credit - v_credited;

  IF v_credited > 0 THEN
    UPDATE public.wallets SET balance = COALESCE(balance, 0) + v_credited, updated_at = now() WHERE id = v_wallet_id;
  END IF;

  RETURN jsonb_build_object('credited', v_credited, 'currency', v_wallet_cur, 'wallet_id', v_wallet_id,
    'quarantined', v_q_amt, 'capped', (v_q_amt > 0));
END;
$$;
REVOKE ALL ON FUNCTION public.credit_user_wallet_safe(uuid, numeric, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_user_wallet_safe(uuid, numeric, text, text, text) TO authenticated, service_role;

-- ───────────── Transfert same-currency : plafond sur le crédit destinataire ─────────────
CREATE OR REPLACE FUNCTION public.execute_atomic_wallet_transfer(
  p_sender_id uuid, p_receiver_id uuid, p_amount numeric, p_description text,
  p_sender_wallet_id bigint, p_recipient_wallet_id bigint,
  p_sender_balance_before numeric, p_recipient_balance_before numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_tx_id uuid := gen_random_uuid();
  v_sender_balance numeric;
  v_recipient_balance numeric;
  v_sender_blocked boolean;
  v_recipient_cur text;
  v_credited numeric;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Montant invalide'; END IF;

  IF p_sender_wallet_id <= p_recipient_wallet_id THEN
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
  ELSE
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
  END IF;

  SELECT balance, COALESCE(is_blocked, false) INTO v_sender_balance, v_sender_blocked
  FROM wallets WHERE id = p_sender_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sender wallet not found'; END IF;
  IF v_sender_blocked THEN RAISE EXCEPTION 'Sender wallet blocked'; END IF;

  SELECT balance, currency INTO v_recipient_balance, v_recipient_cur FROM wallets WHERE id = p_recipient_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Recipient wallet not found'; END IF;

  IF v_sender_balance < p_amount THEN RAISE EXCEPTION 'Solde insuffisant'; END IF;

  -- Plafond destinataire : l'excédent part en quarantaine, le reste est crédité.
  v_credited := public.apply_wallet_cap_split(p_receiver_id, p_recipient_wallet_id, v_recipient_balance, p_amount, v_recipient_cur, 'transfer_in', v_tx_id::text);

  UPDATE wallets SET balance = v_sender_balance - p_amount, updated_at = now() WHERE id = p_sender_wallet_id;
  UPDATE wallets SET balance = v_recipient_balance + v_credited, updated_at = now() WHERE id = p_recipient_wallet_id;

  INSERT INTO enhanced_transactions (id, sender_id, receiver_id, amount, method, status, currency, metadata)
  VALUES (
    v_tx_id, p_sender_id, p_receiver_id, p_amount, 'wallet', 'completed',
    (SELECT currency FROM wallets WHERE id = p_sender_wallet_id LIMIT 1),
    jsonb_build_object('description', p_description, 'atomic', true, 'transaction_type', 'transfer',
      'credited', v_credited, 'quarantined', (p_amount - v_credited))
  );

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id, 'quarantined', (p_amount - v_credited));
END;
$function$;

-- ───────────── Transfert FX : plafond sur le crédit destinataire ─────────────
CREATE OR REPLACE FUNCTION public.execute_atomic_wallet_transfer_fx(
  p_sender_id uuid, p_receiver_id uuid, p_debit_amount numeric, p_credit_amount numeric,
  p_description text, p_sender_wallet_id bigint, p_recipient_wallet_id bigint,
  p_sender_balance_before numeric, p_recipient_balance_before numeric,
  p_sender_currency text, p_receiver_currency text, p_rate_used numeric,
  p_fee_amount numeric DEFAULT 0
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_tx_id uuid := gen_random_uuid();
  v_sender_balance numeric;
  v_recipient_balance numeric;
  v_sender_blocked boolean;
  v_fee numeric := COALESCE(p_fee_amount, 0);
  v_credited numeric;
BEGIN
  IF p_debit_amount IS NULL OR p_debit_amount <= 0 THEN RAISE EXCEPTION 'Montants invalides'; END IF;
  IF p_credit_amount IS NULL OR p_credit_amount <= 0 THEN RAISE EXCEPTION 'Montants invalides'; END IF;
  IF v_fee < 0 THEN RAISE EXCEPTION 'Commission invalide'; END IF;

  IF p_sender_wallet_id <= p_recipient_wallet_id THEN
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
  ELSE
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
  END IF;

  SELECT balance, COALESCE(is_blocked, false) INTO v_sender_balance, v_sender_blocked
  FROM wallets WHERE id = p_sender_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sender wallet not found'; END IF;
  IF v_sender_blocked THEN RAISE EXCEPTION 'Sender wallet blocked'; END IF;

  SELECT balance INTO v_recipient_balance FROM wallets WHERE id = p_recipient_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Recipient wallet not found'; END IF;

  IF v_sender_balance < p_debit_amount THEN RAISE EXCEPTION 'Solde insuffisant'; END IF;

  -- Plafond destinataire (montant crédité, devise destinataire).
  v_credited := public.apply_wallet_cap_split(p_receiver_id, p_recipient_wallet_id, v_recipient_balance, p_credit_amount, p_receiver_currency, 'transfer_in', v_tx_id::text);

  UPDATE wallets SET balance = v_sender_balance - p_debit_amount, updated_at = now() WHERE id = p_sender_wallet_id;
  UPDATE wallets SET balance = v_recipient_balance + v_credited, updated_at = now() WHERE id = p_recipient_wallet_id;

  INSERT INTO enhanced_transactions (id, sender_id, receiver_id, amount, method, status, currency, metadata)
  VALUES (
    v_tx_id, p_sender_id, p_receiver_id, p_debit_amount, 'wallet', 'completed', p_sender_currency,
    jsonb_build_object(
      'description', p_description, 'atomic', true, 'fx', true, 'transaction_type', 'transfer',
      'amount_sent', (p_debit_amount - v_fee), 'amount_received', p_credit_amount, 'credit_amount', p_credit_amount,
      'credited', v_credited, 'quarantined', (p_credit_amount - v_credited),
      'fee_amount', v_fee, 'sender_currency', p_sender_currency,
      'receiver_currency', p_receiver_currency, 'rate_used', p_rate_used
    )
  );

  IF v_fee > 0 THEN
    INSERT INTO platform_fx_commissions (transaction_id, sender_id, receiver_id, amount, currency, rate_used)
    VALUES (v_tx_id, p_sender_id, p_receiver_id, v_fee, p_sender_currency, p_rate_used);
  END IF;

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id, 'quarantined', (p_credit_amount - v_credited));
END;
$function$;

REVOKE ALL ON FUNCTION public.execute_atomic_wallet_transfer(uuid, uuid, numeric, text, bigint, bigint, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.execute_atomic_wallet_transfer(uuid, uuid, numeric, text, bigint, bigint, numeric, numeric) TO service_role;
REVOKE ALL ON FUNCTION public.execute_atomic_wallet_transfer_fx(uuid, uuid, numeric, numeric, text, bigint, bigint, numeric, numeric, text, text, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.execute_atomic_wallet_transfer_fx(uuid, uuid, numeric, numeric, text, bigint, bigint, numeric, numeric, text, text, numeric, numeric) TO service_role;

SELECT 'AML phase 2 : plafond + quarantaine sur transferts (same+FX) et dépôts (via credit_user_wallet_safe).' AS status;
