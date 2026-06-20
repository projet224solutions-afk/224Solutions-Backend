
-- Insérer le paramètre panic_mode dans system_settings s'il n'existe pas
INSERT INTO system_settings (setting_key, setting_value, description)
VALUES ('panic_mode', 'false', 'Mode panique - bloque toutes les transactions financières')
ON CONFLICT (setting_key) DO NOTHING;

-- Créer une fonction helper pour vérifier le panic mode
CREATE OR REPLACE FUNCTION is_panic_mode_active()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN COALESCE(
    (SELECT setting_value::boolean FROM system_settings WHERE setting_key = 'panic_mode'),
    false
  );
END;
$$;

-- Recréer process_secure_wallet_transfer avec la bonne vérification panic mode
CREATE OR REPLACE FUNCTION process_secure_wallet_transfer(
  p_sender_id UUID,
  p_receiver_id UUID,
  p_amount NUMERIC,
  p_currency VARCHAR DEFAULT 'GNF',
  p_description TEXT DEFAULT NULL,
  p_sender_type VARCHAR DEFAULT 'user',
  p_receiver_type VARCHAR DEFAULT 'user'
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_transaction_id UUID := gen_random_uuid();
  v_fee_percentage NUMERIC := 0.01;
  v_fee_amount NUMERIC;
  v_total_debit NUMERIC;
  v_sender_balance NUMERIC;
  v_receiver_balance NUMERIC;
  v_previous_hash TEXT;
  v_ledger_hash TEXT;
  v_current_hour INTEGER;
BEGIN
  -- Vérifier le mode panique
  IF is_panic_mode_active() THEN
    -- Créer une alerte pour le PDG
    INSERT INTO pdg_financial_alerts (alert_type, severity, title, message, related_transaction_id, is_read)
    VALUES ('panic_blocked', 'critical', 'Transaction bloquée - Mode Panique', 
            'Transaction de ' || p_amount || ' ' || p_currency || ' bloquée par le mode panique', 
            v_transaction_id, false);
    RAISE EXCEPTION 'Mode panique activé - toutes les transactions sont suspendues';
  END IF;

  -- Calculer les frais
  v_fee_amount := ROUND(p_amount * v_fee_percentage, 2);
  v_total_debit := p_amount + v_fee_amount;
  v_current_hour := EXTRACT(HOUR FROM NOW());

  -- Obtenir le solde de l'expéditeur selon son type
  IF p_sender_type = 'agent' THEN
    SELECT COALESCE(balance, 0) INTO v_sender_balance 
    FROM agent_wallets WHERE agent_id = p_sender_id;
  ELSIF p_sender_type = 'bureau' THEN
    SELECT COALESCE(balance, 0) INTO v_sender_balance 
    FROM bureau_wallets WHERE bureau_id = p_sender_id;
  ELSE
    SELECT COALESCE(balance, 0) INTO v_sender_balance 
    FROM wallets WHERE user_id = p_sender_id;
  END IF;

  -- Vérifier le solde suffisant
  IF v_sender_balance IS NULL OR v_sender_balance < v_total_debit THEN
    INSERT INTO pdg_financial_alerts (alert_type, severity, title, message, related_transaction_id, is_read)
    VALUES ('insufficient_balance', 'warning', 'Solde insuffisant', 
            'Tentative de transfert de ' || p_amount || ' ' || p_currency || ' avec solde de ' || COALESCE(v_sender_balance, 0), 
            v_transaction_id, false);
    RAISE EXCEPTION 'Solde insuffisant: % disponible, % requis', COALESCE(v_sender_balance, 0), v_total_debit;
  END IF;

  -- Obtenir le solde du destinataire
  IF p_receiver_type = 'agent' THEN
    SELECT COALESCE(balance, 0) INTO v_receiver_balance 
    FROM agent_wallets WHERE agent_id = p_receiver_id;
    IF v_receiver_balance IS NULL THEN
      INSERT INTO agent_wallets (agent_id, balance, currency) VALUES (p_receiver_id, 0, p_currency);
      v_receiver_balance := 0;
    END IF;
  ELSIF p_receiver_type = 'bureau' THEN
    SELECT COALESCE(balance, 0) INTO v_receiver_balance 
    FROM bureau_wallets WHERE bureau_id = p_receiver_id;
    IF v_receiver_balance IS NULL THEN
      INSERT INTO bureau_wallets (bureau_id, balance, currency) VALUES (p_receiver_id, 0, p_currency);
      v_receiver_balance := 0;
    END IF;
  ELSE
    SELECT COALESCE(balance, 0) INTO v_receiver_balance 
    FROM wallets WHERE user_id = p_receiver_id;
    IF v_receiver_balance IS NULL THEN
      INSERT INTO wallets (user_id, balance, currency) VALUES (p_receiver_id, 0, p_currency);
      v_receiver_balance := 0;
    END IF;
  END IF;

  -- Obtenir le hash précédent pour la chaîne
  SELECT ledger_hash INTO v_previous_hash 
  FROM financial_ledger ORDER BY created_at DESC LIMIT 1;
  
  -- Calculer le hash SHA-256
  v_ledger_hash := encode(sha256(
    (v_transaction_id::text || p_sender_id::text || p_receiver_id::text || 
     p_amount::text || v_sender_balance::text || v_receiver_balance::text || 
     COALESCE(v_previous_hash, 'genesis'))::bytea
  ), 'hex');

  -- Enregistrer dans le ledger immutable
  INSERT INTO financial_ledger (
    transaction_id, actor_id, actor_type, debit_account, credit_account,
    amount, currency, balance_before_debit, balance_after_debit,
    balance_before_credit, balance_after_credit, transaction_type,
    description, ledger_hash, previous_hash, module_name, is_valid, validation_status
  ) VALUES (
    v_transaction_id, p_sender_id, p_sender_type, p_sender_id::text, p_receiver_id::text,
    p_amount, p_currency, v_sender_balance, v_sender_balance - v_total_debit,
    v_receiver_balance, v_receiver_balance + p_amount, 'transfer',
    COALESCE(p_description, 'Transfert wallet'), v_ledger_hash, v_previous_hash,
    'process_secure_wallet_transfer', true, 'confirmed'
  );

  -- Mettre à jour le wallet de l'expéditeur
  IF p_sender_type = 'agent' THEN
    UPDATE agent_wallets SET balance = balance - v_total_debit, updated_at = NOW() WHERE agent_id = p_sender_id;
  ELSIF p_sender_type = 'bureau' THEN
    UPDATE bureau_wallets SET balance = balance - v_total_debit, updated_at = NOW() WHERE bureau_id = p_sender_id;
  ELSE
    UPDATE wallets SET balance = balance - v_total_debit, updated_at = NOW() WHERE user_id = p_sender_id;
  END IF;

  -- Mettre à jour le wallet du destinataire
  IF p_receiver_type = 'agent' THEN
    UPDATE agent_wallets SET balance = balance + p_amount, updated_at = NOW() WHERE agent_id = p_receiver_id;
  ELSIF p_receiver_type = 'bureau' THEN
    UPDATE bureau_wallets SET balance = balance + p_amount, updated_at = NOW() WHERE bureau_id = p_receiver_id;
  ELSE
    UPDATE wallets SET balance = balance + p_amount, updated_at = NOW() WHERE user_id = p_receiver_id;
  END IF;

  -- Synchroniser agent_wallets si c'est un agent dans la table wallets
  IF p_sender_type = 'user' THEN
    UPDATE agent_wallets SET balance = (SELECT balance FROM wallets WHERE user_id = p_sender_id), updated_at = NOW()
    WHERE agent_id IN (SELECT id FROM agents_management WHERE user_id = p_sender_id);
  END IF;
  IF p_receiver_type = 'user' THEN
    UPDATE agent_wallets SET balance = (SELECT balance FROM wallets WHERE user_id = p_receiver_id), updated_at = NOW()
    WHERE agent_id IN (SELECT id FROM agents_management WHERE user_id = p_receiver_id);
  END IF;

  -- Créer la transaction dans wallet_transactions
  INSERT INTO wallet_transactions (
    sender_id, receiver_id, amount, fee_amount, currency, 
    transaction_type, status, description, metadata
  ) VALUES (
    p_sender_id, p_receiver_id, p_amount, v_fee_amount, p_currency,
    'transfer', 'completed', p_description,
    jsonb_build_object(
      'ledger_id', v_transaction_id,
      'sender_type', p_sender_type,
      'receiver_type', p_receiver_type,
      'fee_percentage', v_fee_percentage
    )
  );

  -- Mettre à jour les statistiques PDG
  INSERT INTO pdg_financial_stats (
    stat_date, stat_hour, total_transactions, total_volume, 
    successful_transactions, failed_transactions, total_fees_collected
  ) VALUES (
    CURRENT_DATE, v_current_hour, 1, p_amount, 1, 0, v_fee_amount
  )
  ON CONFLICT (stat_date, stat_hour) DO UPDATE SET
    total_transactions = pdg_financial_stats.total_transactions + 1,
    total_volume = pdg_financial_stats.total_volume + p_amount,
    successful_transactions = pdg_financial_stats.successful_transactions + 1,
    total_fees_collected = pdg_financial_stats.total_fees_collected + v_fee_amount,
    updated_at = NOW();

  RETURN v_transaction_id;
END;
$$;

-- Initialiser les statistiques de base si vides
INSERT INTO pdg_financial_stats (stat_date, stat_hour, total_transactions, total_volume, successful_transactions, failed_transactions, total_fees_collected)
SELECT CURRENT_DATE, EXTRACT(HOUR FROM NOW())::integer, 0, 0, 0, 0, 0
WHERE NOT EXISTS (SELECT 1 FROM pdg_financial_stats WHERE stat_date = CURRENT_DATE);
