-- ============================================================================
-- FIX CRITIQUE — wallet_debit_internal : v_wallet_id était déclaré `uuid` alors que
-- `wallets.id` est BIGINT → `SELECT id INTO v_wallet_id` plantait avec
-- « invalid input syntax for type uuid: "723" » → TOUT débit via cette primitive
-- échouait (paiement restaurant, achat d'abonnement, etc.). Correctif : type bigint.
-- Le reste du corps est inchangé. CREATE OR REPLACE conserve les privilèges existants.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.wallet_debit_internal(
  p_user_id uuid,
  p_amount numeric,
  p_description text,
  p_idempotency_key text
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id bigint;     -- ⚠️ ÉTAIT uuid → corrigé en bigint (wallets.id est bigint)
  v_balance numeric;
  v_blocked boolean;
  v_currency text;
BEGIN
  IF p_amount IS NULL OR p_amount = 0 THEN
    RETURN NULL; -- plan gratuit : aucun débit
  END IF;
  IF p_amount < 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT';
  END IF;

  SELECT id, balance, COALESCE(is_blocked, false), COALESCE(currency, 'GNF')
  INTO   v_wallet_id, v_balance, v_blocked, v_currency
  FROM   public.wallets
  WHERE  user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'WALLET_NOT_FOUND'; END IF;
  IF v_blocked THEN RAISE EXCEPTION 'WALLET_BLOCKED'; END IF;

  IF p_idempotency_key IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.wallet_idempotency_keys WHERE idempotency_key = p_idempotency_key) THEN
    RAISE EXCEPTION 'DUPLICATE_PAYMENT';
  END IF;

  IF v_balance < p_amount THEN RAISE EXCEPTION 'INSUFFICIENT_FUNDS'; END IF;

  UPDATE public.wallets
  SET balance = v_balance - p_amount, updated_at = now()
  WHERE id = v_wallet_id;

  INSERT INTO public.wallet_transactions (
    transaction_id, sender_wallet_id, receiver_wallet_id, sender_user_id, receiver_user_id,
    transaction_type, amount, net_amount, status, currency, description, metadata
  ) VALUES (
    gen_random_uuid(), v_wallet_id, NULL, p_user_id, NULL,
    'withdrawal', p_amount, p_amount, 'completed', v_currency, p_description,
    jsonb_build_object('idempotency_key', p_idempotency_key, 'source', 'backend-rpc-atomic')
  );

  BEGIN
    INSERT INTO public.wallet_idempotency_keys (idempotency_key, user_id, operation, created_at, expires_at)
    VALUES (p_idempotency_key, p_user_id, 'withdraw', now(), now() + interval '24 hours');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_balance - p_amount;
END;
$$;

SELECT 'Fix : wallet_debit_internal.v_wallet_id uuid → bigint (débit réparé).' AS status;
