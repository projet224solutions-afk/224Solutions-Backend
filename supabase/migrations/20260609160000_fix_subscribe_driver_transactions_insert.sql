-- ============================================================================
-- FIX — subscribe_driver : INSERT dans `transactions` invalide (abonnement cassé)
-- ----------------------------------------------------------------------------
-- Erreur live : « column "type" of relation "transactions" does not exist » → le
-- renouvellement d'abonnement (taxi/livreur, paiement wallet) échouait.
-- La table `transactions` réelle = (user_id, order_id, amount, method [enum NOT NULL],
-- status [enum], reference_number, description, created_at, updated_at). La fonction
-- insérait `type` (inexistant), `reference` (→ `reference_number`) et OUBLIAIT `method`
-- (NOT NULL). Correctif de l'INSERT uniquement (method='wallet', reference_number, sans
-- type) ; tout le reste de la logique d'abonnement est conservé à l'identique.
-- Non destructif, rejouable.
-- ============================================================================

CREATE OR REPLACE FUNCTION subscribe_driver(
  p_user_id UUID,
  p_type TEXT,
  p_payment_method TEXT DEFAULT 'wallet',
  p_transaction_id TEXT DEFAULT NULL,
  p_billing_cycle TEXT DEFAULT 'monthly'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_price NUMERIC;
  v_duration_days INTEGER;
  v_subscription_id UUID;
  v_end_date TIMESTAMPTZ;
  v_wallet_balance NUMERIC;
  v_transaction_code TEXT;
  v_transaction_id UUID;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'User ID requis';
  END IF;

  IF p_type NOT IN ('taxi', 'livreur') THEN
    RAISE EXCEPTION 'Type invalide. Doit être taxi ou livreur';
  END IF;

  IF p_billing_cycle = 'yearly' THEN
    SELECT COALESCE(yearly_price, price * 12), 365 INTO v_price, v_duration_days
    FROM driver_subscription_config
    WHERE subscription_type IN ('both', p_type) AND is_active = TRUE
    ORDER BY subscription_type = 'both' DESC
    LIMIT 1;
  ELSE
    SELECT price, duration_days INTO v_price, v_duration_days
    FROM driver_subscription_config
    WHERE subscription_type IN ('both', p_type) AND is_active = TRUE
    ORDER BY subscription_type = 'both' DESC
    LIMIT 1;
  END IF;

  IF v_price IS NULL THEN
    v_price := 50000;
    v_duration_days := 30;
    RAISE NOTICE 'Utilisation configuration par défaut: % GNF pour % jours', v_price, v_duration_days;
  END IF;

  IF p_payment_method = 'wallet' THEN
    SELECT balance INTO v_wallet_balance
    FROM wallets
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF v_wallet_balance IS NULL THEN
      INSERT INTO wallets (user_id, balance, currency)
      VALUES (p_user_id, 0, 'GNF')
      ON CONFLICT (user_id) DO NOTHING;
      v_wallet_balance := 0;
    END IF;

    IF v_wallet_balance < v_price THEN
      RAISE EXCEPTION 'Solde insuffisant. Solde: % GNF, Prix: % GNF', v_wallet_balance, v_price;
    END IF;

    UPDATE wallets
    SET balance = balance - v_price, updated_at = NOW()
    WHERE user_id = p_user_id;

    v_transaction_code := 'SUB-' || EXTRACT(EPOCH FROM NOW())::BIGINT || '-' || SUBSTRING(p_user_id::TEXT, 1, 8);

    -- ✅ INSERT corrigé : colonnes réelles de `transactions` (method NOT NULL, reference_number, pas de type).
    INSERT INTO transactions (
      user_id,
      amount,
      method,
      status,
      description,
      reference_number,
      created_at
    ) VALUES (
      p_user_id,
      -v_price,                         -- débit (négatif)
      'wallet',                         -- payment_method_type valide
      'completed',                      -- transaction_status_type valide
      'Abonnement ' || UPPER(p_type) || ' - ' || INITCAP(p_billing_cycle),
      v_transaction_code,
      NOW()
    ) RETURNING id INTO v_transaction_id;
  ELSE
    v_transaction_code := COALESCE(p_transaction_id, 'SUB-' || EXTRACT(EPOCH FROM NOW())::BIGINT || '-' || SUBSTRING(p_user_id::TEXT, 1, 8));
    v_wallet_balance := 0;
  END IF;

  v_end_date := NOW() + (v_duration_days || ' days')::INTERVAL;

  UPDATE driver_subscriptions
  SET status = 'expired', updated_at = NOW()
  WHERE user_id = p_user_id AND status = 'active';

  INSERT INTO driver_subscriptions (
    user_id, type, price, status, start_date, end_date,
    payment_method, transaction_id, billing_cycle, metadata
  ) VALUES (
    p_user_id, p_type, v_price, 'active', NOW(), v_end_date,
    p_payment_method, v_transaction_code, p_billing_cycle,
    jsonb_build_object(
      'wallet_transaction_id', v_transaction_id,
      'subscribed_at', NOW(),
      'original_balance', v_wallet_balance,
      'new_balance', CASE WHEN p_payment_method = 'wallet' THEN v_wallet_balance - v_price ELSE NULL END
    )
  ) RETURNING id INTO v_subscription_id;

  IF v_price > 0 THEN
    INSERT INTO driver_subscription_revenues (
      subscription_id, user_id, amount, payment_method, transaction_id
    ) VALUES (
      v_subscription_id, p_user_id, v_price, p_payment_method, v_transaction_code
    );
  END IF;

  RETURN v_subscription_id;
END;
$$;

SELECT 'subscribe_driver corrigé : INSERT transactions valide (method/reference_number, sans type).' AS status;
