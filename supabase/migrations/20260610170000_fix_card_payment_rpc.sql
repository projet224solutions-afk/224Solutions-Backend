-- ============================================================================
-- 💳 RÉPARATION DU PAIEMENT PAR CARTE VIRTUELLE - 224SOLUTIONS
-- ============================================================================
-- BUG : process_card_payment insérait dans
--   wallet_transactions (wallet_id, type, currency, reference_id, ...)
-- alors que la VRAIE table a les colonnes
--   (sender_wallet_id, receiver_wallet_id, transaction_type, metadata, ...).
-- → l'INSERT plantait, toute la transaction était annulée (rollback), donc
--   AUCUN paiement carte ne réussissait (table card_transactions vide).
--
-- CORRECTION :
--   1. Insertion wallet_transactions avec les bonnes colonnes.
--   2. Sélection du wallet rendue MULTI-DEVISES : on prend le wallet de
--      l'utilisateur en privilégiant GNF (base), sinon n'importe lequel
--      (avant : forcé sur GNF → échec pour un utilisateur sans wallet GNF).
--   3. transaction_type = 'payment' (valeur connue/valide de la table).
-- Le reste de la logique (limites, compteurs, expiration) est conservé.
-- ============================================================================

CREATE OR REPLACE FUNCTION process_card_payment(
  p_card_id UUID,
  p_amount DECIMAL,
  p_merchant_name VARCHAR,
  p_merchant_category VARCHAR DEFAULT NULL,
  p_description TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_card RECORD;
  v_wallet RECORD;
  v_user_id UUID;
  v_reference_code VARCHAR;
  v_transaction_id UUID;
  v_current_date DATE;
  v_current_month DATE;
BEGIN
  SELECT * INTO v_card FROM virtual_cards WHERE id = p_card_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Carte non trouvée');
  END IF;

  v_user_id := v_card.user_id;
  v_current_date := CURRENT_DATE;
  v_current_month := DATE_TRUNC('month', CURRENT_DATE);

  IF auth.uid() IS NULL OR auth.uid() != v_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Non autorisé');
  END IF;

  IF v_card.status != 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Carte inactive ou bloquée');
  END IF;

  -- Réinitialiser les compteurs si nécessaire
  IF v_card.last_daily_reset::DATE < v_current_date THEN
    UPDATE virtual_cards SET daily_spent = 0, last_daily_reset = now() WHERE id = p_card_id;
    v_card.daily_spent := 0;
  END IF;

  IF DATE_TRUNC('month', v_card.last_monthly_reset) < v_current_month THEN
    UPDATE virtual_cards SET monthly_spent = 0, last_monthly_reset = now() WHERE id = p_card_id;
    v_card.monthly_spent := 0;
  END IF;

  -- Limites
  IF v_card.daily_limit IS NOT NULL AND (v_card.daily_spent + p_amount) > v_card.daily_limit THEN
    RETURN jsonb_build_object(
      'success', false, 'error', 'Limite journalière dépassée',
      'daily_limit', v_card.daily_limit, 'daily_spent', v_card.daily_spent,
      'remaining', v_card.daily_limit - v_card.daily_spent
    );
  END IF;

  IF v_card.monthly_limit IS NOT NULL AND (v_card.monthly_spent + p_amount) > v_card.monthly_limit THEN
    RETURN jsonb_build_object(
      'success', false, 'error', 'Limite mensuelle dépassée',
      'monthly_limit', v_card.monthly_limit, 'monthly_spent', v_card.monthly_spent,
      'remaining', v_card.monthly_limit - v_card.monthly_spent
    );
  END IF;

  -- ✅ MULTI-DEVISES : wallet de l'utilisateur, GNF prioritaire sinon le premier
  SELECT * INTO v_wallet
  FROM wallets
  WHERE user_id = v_user_id
  ORDER BY (currency = 'GNF') DESC, created_at ASC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet non trouvé');
  END IF;

  IF v_wallet.balance < p_amount THEN
    RETURN jsonb_build_object(
      'success', false, 'error', 'Solde insuffisant',
      'balance', v_wallet.balance, 'required', p_amount
    );
  END IF;

  v_reference_code := 'TXN-' || UPPER(SUBSTRING(gen_random_uuid()::TEXT, 1, 8)) || '-' || TO_CHAR(now(), 'YYYYMMDD');

  -- Débiter le wallet
  UPDATE wallets SET balance = balance - p_amount, updated_at = now() WHERE id = v_wallet.id;

  -- Transaction carte
  INSERT INTO card_transactions (
    card_id, user_id, wallet_id, amount, merchant_name,
    merchant_category, description, reference_code, status
  ) VALUES (
    p_card_id, v_user_id, v_wallet.id, p_amount, p_merchant_name,
    p_merchant_category, p_description, v_reference_code, 'completed'
  ) RETURNING id INTO v_transaction_id;

  -- Compteurs carte
  UPDATE virtual_cards SET
    daily_spent = daily_spent + p_amount,
    monthly_spent = monthly_spent + p_amount,
    total_spent = total_spent + p_amount,
    transaction_count = transaction_count + 1
  WHERE id = p_card_id;

  -- ✅ Grand livre wallet : COLONNES CORRECTES (débit = sortie)
  INSERT INTO wallet_transactions (
    sender_wallet_id, receiver_wallet_id, amount, transaction_type, status, description, metadata
  ) VALUES (
    v_wallet.id, NULL, p_amount, 'payment', 'completed',
    'Paiement carte: ' || p_merchant_name,
    jsonb_build_object(
      'source', 'virtual_card',
      'card_id', p_card_id,
      'reference_code', v_reference_code,
      'merchant_name', p_merchant_name,
      'merchant_category', p_merchant_category
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'reference_code', v_reference_code,
    'amount', p_amount,
    'new_balance', v_wallet.balance - p_amount,
    'daily_remaining', v_card.daily_limit - v_card.daily_spent - p_amount,
    'monthly_remaining', v_card.monthly_limit - v_card.monthly_spent - p_amount
  );
END;
$$;
