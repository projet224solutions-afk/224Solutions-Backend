
-- ================================================================
-- INTÉGRATION DU SYSTÈME BANCAIRE - VERSION CORRIGÉE
-- ================================================================

-- 1. Ajouter la colonne updated_at et total_fees_collected si absentes
ALTER TABLE pdg_financial_stats 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now(),
ADD COLUMN IF NOT EXISTS total_fees_collected NUMERIC DEFAULT 0;

-- 2. Recréer la fonction de transfert avec intégration bancaire
DROP FUNCTION IF EXISTS process_secure_wallet_transfer(UUID, UUID, NUMERIC, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION process_secure_wallet_transfer(
  p_sender_id UUID,
  p_receiver_id UUID,
  p_amount NUMERIC,
  p_description TEXT DEFAULT NULL,
  p_sender_type TEXT DEFAULT 'user',
  p_receiver_type TEXT DEFAULT 'user'
)
RETURNS JSONB
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
  v_current_hour INTEGER;
BEGIN
  v_current_hour := EXTRACT(HOUR FROM now())::INTEGER;

  -- ============================================
  -- PHASE 0: VÉRIFICATION PANIC MODE
  -- ============================================
  SELECT EXISTS(
    SELECT 1 FROM pdg_financial_control 
    WHERE control_type IN ('panic_mode', 'freeze_all') 
    AND is_active = true
  ) INTO v_panic_active;
  
  IF v_panic_active THEN
    INSERT INTO pdg_financial_alerts (alert_type, severity, title, message, amount, is_read)
    VALUES ('blocked_transaction', 'high', 'Transaction bloquée - Mode Panic', 
            format('Tentative de transfert de %s GNF bloquée', p_amount), p_amount, false);
    
    RETURN jsonb_build_object(
      'success', false,
      'error', 'PANIC_MODE_ACTIVE',
      'message', 'Système en mode urgence. Transactions gelées.'
    );
  END IF;

  v_transaction_id := 'TXN-' || to_char(now(), 'YYYYMMDD-HH24MISS-') || substr(gen_random_uuid()::text, 1, 8);

  -- RÉSOLUTION WALLETS EXPÉDITEUR
  IF p_sender_type = 'bureau' THEN
    SELECT id, balance INTO v_sender_wallet_id, v_sender_balance
    FROM bureau_wallets WHERE bureau_id = p_sender_id AND wallet_status = 'active';
    v_sender_user_id := NULL;
  ELSIF p_sender_type = 'agent' THEN
    SELECT am.user_id INTO v_sender_user_id FROM agents_management am WHERE am.id = p_sender_id;
    IF v_sender_user_id IS NULL THEN v_sender_user_id := p_sender_id; END IF;
    SELECT id, balance INTO v_sender_wallet_id, v_sender_balance
    FROM wallets WHERE user_id = v_sender_user_id AND status = 'active';
  ELSE
    v_sender_user_id := p_sender_id;
    SELECT id, balance INTO v_sender_wallet_id, v_sender_balance
    FROM wallets WHERE user_id = p_sender_id AND status = 'active';
  END IF;

  IF v_sender_wallet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet expéditeur non trouvé');
  END IF;

  -- RÉSOLUTION WALLETS DESTINATAIRE
  IF p_receiver_type = 'bureau' THEN
    SELECT id, balance INTO v_receiver_wallet_id, v_receiver_balance
    FROM bureau_wallets WHERE bureau_id = p_receiver_id AND wallet_status = 'active';
    v_receiver_user_id := NULL;
  ELSIF p_receiver_type = 'agent' THEN
    SELECT am.user_id INTO v_receiver_user_id FROM agents_management am WHERE am.id = p_receiver_id;
    IF v_receiver_user_id IS NULL THEN v_receiver_user_id := p_receiver_id; END IF;
    SELECT id, balance INTO v_receiver_wallet_id, v_receiver_balance
    FROM wallets WHERE user_id = v_receiver_user_id AND status = 'active';
    IF v_receiver_wallet_id IS NULL THEN
      INSERT INTO wallets (user_id, balance, currency, status)
      VALUES (v_receiver_user_id, 0, 'GNF', 'active')
      RETURNING id, balance INTO v_receiver_wallet_id, v_receiver_balance;
    END IF;
  ELSE
    v_receiver_user_id := p_receiver_id;
    SELECT id, balance INTO v_receiver_wallet_id, v_receiver_balance
    FROM wallets WHERE user_id = p_receiver_id AND status = 'active';
    IF v_receiver_wallet_id IS NULL THEN
      INSERT INTO wallets (user_id, balance, currency, status)
      VALUES (p_receiver_id, 0, 'GNF', 'active')
      RETURNING id, balance INTO v_receiver_wallet_id, v_receiver_balance;
    END IF;
  END IF;

  IF v_receiver_wallet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet destinataire non trouvé');
  END IF;

  -- CALCULS
  v_fee_amount := ROUND(p_amount * v_fee_rate, 0);
  v_net_amount := p_amount - v_fee_amount;

  IF v_sender_balance < p_amount THEN
    -- Stats échec
    INSERT INTO pdg_financial_stats (stat_date, stat_hour, total_transactions, failed_transactions, total_volume)
    VALUES (CURRENT_DATE, v_current_hour, 1, 1, p_amount)
    ON CONFLICT (stat_date, stat_hour) DO UPDATE SET
      total_transactions = pdg_financial_stats.total_transactions + 1,
      failed_transactions = pdg_financial_stats.failed_transactions + 1;
    
    RETURN jsonb_build_object(
      'success', false,
      'error', format('Solde insuffisant. Disponible: %s, Requis: %s', v_sender_balance, p_amount)
    );
  END IF;

  v_sender_balance_after := v_sender_balance - p_amount;
  v_receiver_balance_after := v_receiver_balance + v_net_amount;

  -- LEDGER IMMUABLE
  SELECT ledger_hash INTO v_previous_hash FROM financial_ledger ORDER BY created_at DESC LIMIT 1;
  IF v_previous_hash IS NULL THEN v_previous_hash := 'GENESIS'; END IF;
  
  v_ledger_hash := encode(sha256(
    (v_transaction_id || COALESCE(v_sender_user_id::text, p_sender_id::text) || 
     COALESCE(v_receiver_user_id::text, p_receiver_id::text) || p_amount::text || v_previous_hash)::bytea
  ), 'hex');

  INSERT INTO financial_ledger (
    transaction_id, actor_id, actor_type, debit_account, credit_account,
    amount, balance_before, balance_after, expected_balance, is_valid,
    ledger_hash, previous_hash, transaction_type, status, metadata
  ) VALUES (
    v_transaction_id, COALESCE(v_sender_user_id, p_sender_id), p_sender_type,
    v_sender_wallet_id::text, v_receiver_wallet_id::text,
    p_amount, v_sender_balance, v_sender_balance_after, v_sender_balance_after, true,
    v_ledger_hash, v_previous_hash, 'transfer', 'completed',
    jsonb_build_object('fee', v_fee_amount, 'net_amount', v_net_amount,
      'sender_type', p_sender_type, 'receiver_type', p_receiver_type)
  ) RETURNING id INTO v_ledger_id;

  -- MISE À JOUR WALLETS
  IF p_sender_type = 'bureau' THEN
    UPDATE bureau_wallets SET balance = v_sender_balance_after, updated_at = now() WHERE id = v_sender_wallet_id;
  ELSE
    UPDATE wallets SET balance = v_sender_balance_after, updated_at = now() WHERE id = v_sender_wallet_id;
    UPDATE agent_wallets SET balance = v_sender_balance_after, updated_at = now()
    WHERE agent_id IN (SELECT id FROM agents_management WHERE user_id = v_sender_user_id);
  END IF;

  IF p_receiver_type = 'bureau' THEN
    UPDATE bureau_wallets SET balance = v_receiver_balance_after, updated_at = now() WHERE id = v_receiver_wallet_id;
  ELSE
    UPDATE wallets SET balance = v_receiver_balance_after, updated_at = now() WHERE id = v_receiver_wallet_id;
    UPDATE agent_wallets SET balance = v_receiver_balance_after, updated_at = now()
    WHERE agent_id IN (SELECT id FROM agents_management WHERE user_id = v_receiver_user_id);
  END IF;

  -- WALLET_TRANSACTIONS
  INSERT INTO wallet_transactions (
    transaction_id, sender_wallet_id, receiver_wallet_id,
    amount, fee, net_amount, currency, transaction_type, status,
    description, metadata, created_at, completed_at
  ) VALUES (
    v_transaction_id, v_sender_wallet_id, v_receiver_wallet_id,
    p_amount, v_fee_amount, v_net_amount, 'GNF', 'transfer', 'completed',
    COALESCE(p_description, 'Transfert'),
    jsonb_build_object('ledger_id', v_ledger_id,
      'sender_balance_before', v_sender_balance, 'sender_balance_after', v_sender_balance_after,
      'receiver_balance_before', v_receiver_balance, 'receiver_balance_after', v_receiver_balance_after),
    now(), now()
  );

  -- STATISTIQUES PDG (avec stat_hour)
  INSERT INTO pdg_financial_stats (
    stat_date, stat_hour, total_transactions, successful_transactions, total_volume, total_fees_collected
  ) VALUES (CURRENT_DATE, v_current_hour, 1, 1, p_amount, v_fee_amount)
  ON CONFLICT (stat_date, stat_hour) DO UPDATE SET
    total_transactions = pdg_financial_stats.total_transactions + 1,
    successful_transactions = pdg_financial_stats.successful_transactions + 1,
    total_volume = pdg_financial_stats.total_volume + p_amount,
    total_fees_collected = pdg_financial_stats.total_fees_collected + v_fee_amount,
    updated_at = now();

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'ledger_id', v_ledger_id,
    'amount', p_amount,
    'fee', v_fee_amount,
    'net_amount', v_net_amount,
    'sender_balance_after', v_sender_balance_after,
    'receiver_balance_after', v_receiver_balance_after
  );
  
EXCEPTION WHEN OTHERS THEN
  INSERT INTO pdg_financial_stats (stat_date, stat_hour, total_transactions, failed_transactions)
  VALUES (CURRENT_DATE, v_current_hour, 1, 1)
  ON CONFLICT (stat_date, stat_hour) DO UPDATE SET
    total_transactions = pdg_financial_stats.total_transactions + 1,
    failed_transactions = pdg_financial_stats.failed_transactions + 1;
  
  INSERT INTO pdg_financial_alerts (alert_type, severity, title, message, amount, is_read)
  VALUES ('transaction_error', 'critical', 'Erreur de transaction', SQLERRM, p_amount, false);
  
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION process_secure_wallet_transfer(UUID, UUID, NUMERIC, TEXT, TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION process_secure_wallet_transfer IS 'Transfert intégré au système bancaire intelligent avec ledger, stats et panic mode';
