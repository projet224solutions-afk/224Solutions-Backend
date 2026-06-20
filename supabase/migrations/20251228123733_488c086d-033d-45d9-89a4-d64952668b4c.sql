
-- Supprimer la version avec p_currency (7 arguments)
DROP FUNCTION IF EXISTS process_secure_wallet_transfer(UUID, UUID, NUMERIC, VARCHAR, TEXT, VARCHAR, VARCHAR);

-- Recréer la fonction corrigée avec 6 arguments standard
CREATE OR REPLACE FUNCTION process_secure_wallet_transfer(
  p_sender_id UUID,
  p_receiver_id UUID,
  p_amount NUMERIC,
  p_description TEXT DEFAULT NULL,
  p_sender_type TEXT DEFAULT 'user',
  p_receiver_type TEXT DEFAULT 'user'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sender_wallet_id UUID;
  v_receiver_wallet_id UUID;
  v_sender_balance NUMERIC;
  v_receiver_balance NUMERIC;
  v_fee_rate NUMERIC := 0.01;
  v_fee_amount NUMERIC;
  v_net_amount NUMERIC;
  v_sender_balance_after NUMERIC;
  v_receiver_balance_after NUMERIC;
  v_transaction_id TEXT;
  v_sender_user_id UUID;
  v_receiver_user_id UUID;
  v_panic_active BOOLEAN;
  v_ledger_id UUID;
  v_ledger_hash TEXT;
  v_previous_hash TEXT;
BEGIN
  -- VÉRIFICATION PANIC MODE
  SELECT EXISTS(
    SELECT 1 FROM pdg_financial_control 
    WHERE control_type IN ('panic_mode', 'freeze_all') 
    AND is_active = true
  ) INTO v_panic_active;
  
  IF v_panic_active THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'PANIC_MODE_ACTIVE',
      'message', 'Système en mode urgence. Transactions gelées.'
    );
  END IF;

  v_transaction_id := 'TXN-' || to_char(now(), 'YYYYMMDD-HH24MISS-') || substr(gen_random_uuid()::text, 1, 8);

  -- RÉSOLUTION WALLET EXPÉDITEUR (CORRIGÉ: wallet_status au lieu de status)
  IF p_sender_type = 'bureau' THEN
    SELECT id, balance INTO v_sender_wallet_id, v_sender_balance
    FROM bureau_wallets WHERE bureau_id = p_sender_id AND wallet_status = 'active';
    v_sender_user_id := NULL;
  ELSIF p_sender_type = 'agent' THEN
    SELECT am.user_id INTO v_sender_user_id FROM agents_management am WHERE am.id = p_sender_id;
    IF v_sender_user_id IS NULL THEN v_sender_user_id := p_sender_id; END IF;
    SELECT id, balance INTO v_sender_wallet_id, v_sender_balance
    FROM wallets WHERE user_id = v_sender_user_id AND wallet_status = 'active';
  ELSE
    v_sender_user_id := p_sender_id;
    SELECT id, balance INTO v_sender_wallet_id, v_sender_balance
    FROM wallets WHERE user_id = p_sender_id AND wallet_status = 'active';
  END IF;

  IF v_sender_wallet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet expéditeur non trouvé ou inactif');
  END IF;

  -- RÉSOLUTION WALLET DESTINATAIRE (CORRIGÉ: wallet_status au lieu de status)
  IF p_receiver_type = 'bureau' THEN
    SELECT id, balance INTO v_receiver_wallet_id, v_receiver_balance
    FROM bureau_wallets WHERE bureau_id = p_receiver_id AND wallet_status = 'active';
    v_receiver_user_id := NULL;
  ELSIF p_receiver_type = 'agent' THEN
    SELECT am.user_id INTO v_receiver_user_id FROM agents_management am WHERE am.id = p_receiver_id;
    IF v_receiver_user_id IS NULL THEN v_receiver_user_id := p_receiver_id; END IF;
    SELECT id, balance INTO v_receiver_wallet_id, v_receiver_balance
    FROM wallets WHERE user_id = v_receiver_user_id AND wallet_status = 'active';
    IF v_receiver_wallet_id IS NULL THEN
      INSERT INTO wallets (user_id, balance, currency, wallet_status)
      VALUES (v_receiver_user_id, 0, 'GNF', 'active')
      RETURNING id, balance INTO v_receiver_wallet_id, v_receiver_balance;
    END IF;
  ELSE
    v_receiver_user_id := p_receiver_id;
    SELECT id, balance INTO v_receiver_wallet_id, v_receiver_balance
    FROM wallets WHERE user_id = p_receiver_id AND wallet_status = 'active';
    IF v_receiver_wallet_id IS NULL THEN
      INSERT INTO wallets (user_id, balance, currency, wallet_status)
      VALUES (p_receiver_id, 0, 'GNF', 'active')
      RETURNING id, balance INTO v_receiver_wallet_id, v_receiver_balance;
    END IF;
  END IF;

  IF v_receiver_wallet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet destinataire non trouvé ou inactif');
  END IF;

  -- CALCULS
  v_fee_amount := ROUND(p_amount * v_fee_rate, 0);
  v_net_amount := p_amount - v_fee_amount;

  IF v_sender_balance < p_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', format('Solde insuffisant. Disponible: %s GNF', v_sender_balance)
    );
  END IF;

  -- EXÉCUTION DU TRANSFERT
  v_sender_balance_after := v_sender_balance - p_amount;
  v_receiver_balance_after := v_receiver_balance + v_net_amount;

  IF p_sender_type = 'bureau' THEN
    UPDATE bureau_wallets SET balance = v_sender_balance_after, updated_at = now()
    WHERE id = v_sender_wallet_id;
  ELSE
    UPDATE wallets SET balance = v_sender_balance_after, updated_at = now(), last_transaction_at = now()
    WHERE id = v_sender_wallet_id;
  END IF;

  IF p_receiver_type = 'bureau' THEN
    UPDATE bureau_wallets SET balance = v_receiver_balance_after, updated_at = now()
    WHERE id = v_receiver_wallet_id;
  ELSE
    UPDATE wallets SET balance = v_receiver_balance_after, updated_at = now(), last_transaction_at = now()
    WHERE id = v_receiver_wallet_id;
  END IF;

  -- ENREGISTRER DANS LEDGER
  SELECT COALESCE(MAX(txn_hash), 'GENESIS') INTO v_previous_hash FROM financial_ledger;
  v_ledger_hash := encode(sha256((v_previous_hash || v_transaction_id || p_amount::text || now()::text)::bytea), 'hex');

  INSERT INTO financial_ledger (
    transaction_id, sender_wallet_id, receiver_wallet_id, amount, fee,
    sender_balance_before, sender_balance_after, receiver_balance_before, receiver_balance_after,
    transaction_type, description, txn_hash, previous_hash, initiated_by, is_valid, status
  ) VALUES (
    v_transaction_id, v_sender_wallet_id, v_receiver_wallet_id, p_amount, v_fee_amount,
    v_sender_balance, v_sender_balance_after, v_receiver_balance, v_receiver_balance_after,
    'transfer', COALESCE(p_description, 'Transfert wallet'), v_ledger_hash, v_previous_hash,
    'process_secure_wallet_transfer', true, 'confirmed'
  ) RETURNING id INTO v_ledger_id;

  -- ENREGISTRER DANS wallet_transactions
  INSERT INTO wallet_transactions (
    transaction_id, transaction_type, amount, net_amount, fee, currency, 
    status, description, sender_wallet_id, receiver_wallet_id, metadata
  ) VALUES (
    v_transaction_id, 'transfer', p_amount, v_net_amount, v_fee_amount, 'GNF',
    'completed', COALESCE(p_description, 'Transfert wallet'), 
    v_sender_wallet_id, v_receiver_wallet_id,
    jsonb_build_object('sender_type', p_sender_type, 'receiver_type', p_receiver_type, 'ledger_id', v_ledger_id)
  );

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'amount', p_amount,
    'fee', v_fee_amount,
    'net_amount', v_net_amount,
    'sender_balance_after', v_sender_balance_after,
    'receiver_balance_after', v_receiver_balance_after,
    'ledger_id', v_ledger_id
  );
  
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'sqlstate', SQLSTATE);
END;
$$;

-- Permissions
GRANT EXECUTE ON FUNCTION process_secure_wallet_transfer(UUID, UUID, NUMERIC, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION process_secure_wallet_transfer(UUID, UUID, NUMERIC, TEXT, TEXT, TEXT) TO anon;
