
-- Fonction sécurisée pour les transferts de bureau
CREATE OR REPLACE FUNCTION process_secure_bureau_transfer(
  p_bureau_id UUID,
  p_receiver_id UUID,
  p_receiver_type TEXT, -- 'bureau', 'agent', 'vendor', 'user', 'driver'
  p_amount NUMERIC,
  p_description TEXT DEFAULT NULL,
  p_fee_percent NUMERIC DEFAULT 0
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_fee_amount NUMERIC;
  v_total_debit NUMERIC;
  v_bureau_balance_before NUMERIC;
  v_bureau_balance_after NUMERIC;
  v_receiver_balance_before NUMERIC;
  v_receiver_balance_after NUMERIC;
  v_transaction_id UUID;
  v_receiver_agent_id UUID;
  v_reference_number TEXT;
BEGIN
  -- Générer une référence unique
  v_reference_number := 'BUR-TRF-' || EXTRACT(EPOCH FROM now())::TEXT || '-' || floor(random() * 1000)::TEXT;
  
  -- Vérification anti-doublon
  IF EXISTS (
    SELECT 1 FROM bureau_transactions 
    WHERE bureau_id = p_bureau_id 
    AND amount = -p_amount 
    AND created_at > now() - interval '5 seconds'
  ) THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Transaction doublon détectée. Veuillez patienter.',
      'code', 'DUPLICATE_TRANSACTION'
    );
  END IF;
  
  -- Calcul des frais
  v_fee_amount := ROUND((p_amount * p_fee_percent) / 100, 0);
  v_total_debit := p_amount + v_fee_amount;
  
  -- Récupérer le solde du bureau avec verrouillage
  SELECT balance INTO v_bureau_balance_before
  FROM bureau_wallets
  WHERE bureau_id = p_bureau_id
  FOR UPDATE;
  
  IF v_bureau_balance_before IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Wallet bureau introuvable',
      'code', 'BUREAU_WALLET_NOT_FOUND'
    );
  END IF;
  
  -- Vérifier le solde suffisant
  IF v_bureau_balance_before < v_total_debit THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Solde insuffisant',
      'code', 'INSUFFICIENT_BALANCE',
      'required', v_total_debit,
      'current', v_bureau_balance_before
    );
  END IF;
  
  -- Calculer le nouveau solde bureau
  v_bureau_balance_after := v_bureau_balance_before - v_total_debit;
  
  -- Gérer le destinataire selon le type
  IF p_receiver_type = 'bureau' THEN
    SELECT balance INTO v_receiver_balance_before
    FROM bureau_wallets
    WHERE bureau_id = p_receiver_id
    FOR UPDATE;
    
    IF v_receiver_balance_before IS NULL THEN
      RETURN json_build_object('success', false, 'error', 'Bureau destinataire introuvable', 'code', 'RECEIVER_NOT_FOUND');
    END IF;
    
    v_receiver_balance_after := v_receiver_balance_before + p_amount;
    
    -- Créditer le bureau destinataire
    UPDATE bureau_wallets
    SET balance = v_receiver_balance_after, updated_at = now()
    WHERE bureau_id = p_receiver_id;
    
  ELSIF p_receiver_type = 'agent' THEN
    -- Le receiver_id est l'agent_id, récupérer le user_id
    SELECT user_id INTO v_receiver_agent_id FROM agents_management WHERE id = p_receiver_id;
    
    IF v_receiver_agent_id IS NULL THEN
      RETURN json_build_object('success', false, 'error', 'Agent destinataire introuvable', 'code', 'RECEIVER_NOT_FOUND');
    END IF;
    
    SELECT balance INTO v_receiver_balance_before
    FROM wallets WHERE user_id = v_receiver_agent_id FOR UPDATE;
    
    IF v_receiver_balance_before IS NULL THEN
      INSERT INTO wallets (user_id, balance, currency, wallet_status) VALUES (v_receiver_agent_id, 0, 'GNF', 'active');
      v_receiver_balance_before := 0;
    END IF;
    
    v_receiver_balance_after := v_receiver_balance_before + p_amount;
    
    -- Créditer le wallet principal de l'agent
    UPDATE wallets SET balance = v_receiver_balance_after, updated_at = now() WHERE user_id = v_receiver_agent_id;
    
    -- Synchroniser agent_wallets
    UPDATE agent_wallets SET balance = v_receiver_balance_after, updated_at = now() WHERE agent_id = p_receiver_id;
    
  ELSE
    -- vendor, user, driver - tous dans la table wallets
    SELECT balance INTO v_receiver_balance_before
    FROM wallets WHERE user_id = p_receiver_id FOR UPDATE;
    
    IF v_receiver_balance_before IS NULL THEN
      INSERT INTO wallets (user_id, balance, currency, wallet_status) VALUES (p_receiver_id, 0, 'GNF', 'active');
      v_receiver_balance_before := 0;
    END IF;
    
    v_receiver_balance_after := v_receiver_balance_before + p_amount;
    
    UPDATE wallets SET balance = v_receiver_balance_after, updated_at = now() WHERE user_id = p_receiver_id;
  END IF;
  
  -- Débiter le bureau expéditeur
  UPDATE bureau_wallets
  SET balance = v_bureau_balance_after, updated_at = now()
  WHERE bureau_id = p_bureau_id;
  
  -- Enregistrer la transaction dans bureau_transactions
  INSERT INTO bureau_transactions (
    bureau_id, type, amount, date, description, status
  ) VALUES (
    p_bureau_id, 'transfer_out', -v_total_debit, now(), COALESCE(p_description, 'Transfert'), 'completed'
  ) RETURNING id INTO v_transaction_id;
  
  -- Journaliser dans transaction_audit_log
  INSERT INTO transaction_audit_log (
    transaction_id, user_id, user_type, operation_type, amount, fee_amount,
    balance_before, balance_after, expected_balance, is_valid, metadata
  ) VALUES (
    v_transaction_id, p_bureau_id, 'bureau', 'transfer_out', v_total_debit, v_fee_amount,
    v_bureau_balance_before, v_bureau_balance_after, v_bureau_balance_after, true,
    jsonb_build_object('receiver_type', p_receiver_type, 'receiver_id', p_receiver_id, 'description', p_description)
  );
  
  -- Retourner le succès
  RETURN json_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'reference', v_reference_number,
    'amount', p_amount,
    'fee_amount', v_fee_amount,
    'total_debit', v_total_debit,
    'bureau_balance_before', v_bureau_balance_before,
    'bureau_balance_after', v_bureau_balance_after,
    'receiver_balance_before', v_receiver_balance_before,
    'receiver_balance_after', v_receiver_balance_after
  );
  
EXCEPTION
  WHEN OTHERS THEN
    INSERT INTO transaction_audit_log (
      user_id, user_type, operation_type, amount, balance_before, balance_after,
      expected_balance, is_valid, error_message
    ) VALUES (
      p_bureau_id, 'bureau', 'transfer_failed', p_amount, COALESCE(v_bureau_balance_before, 0), 
      COALESCE(v_bureau_balance_before, 0), 0, false, SQLERRM
    );
    
    RETURN json_build_object(
      'success', false,
      'error', 'Erreur lors de la transaction: ' || SQLERRM,
      'code', 'TRANSACTION_FAILED'
    );
END;
$$;
