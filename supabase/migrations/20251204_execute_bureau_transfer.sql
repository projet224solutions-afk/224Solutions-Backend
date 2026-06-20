-- Fonction d'exécution de transfert pour supporter les bureaux syndicats
-- Cette fonction exécute réellement le transfert entre différents types de wallets

CREATE OR REPLACE FUNCTION execute_wallet_transfer_by_code(
  p_sender_code TEXT,
  p_receiver_code TEXT,
  p_amount NUMERIC,
  p_currency VARCHAR DEFAULT 'GNF',
  p_description TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_sender_wallet RECORD;
  v_receiver_wallet RECORD;
  v_fee_amount NUMERIC;
  v_total_debit NUMERIC;
  v_transaction_ref TEXT;
  v_fee_percent NUMERIC;
BEGIN
  -- Trouver les wallets
  SELECT * INTO v_sender_wallet
  FROM find_wallet_by_code(p_sender_code, p_currency);
  
  IF v_sender_wallet.wallet_id IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Expéditeur introuvable: ' || p_sender_code
    );
  END IF;
  
  SELECT * INTO v_receiver_wallet
  FROM find_wallet_by_code(p_receiver_code, p_currency);
  
  IF v_receiver_wallet.wallet_id IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Destinataire introuvable: ' || p_receiver_code
    );
  END IF;
  
  -- Vérifications
  IF v_sender_wallet.wallet_id = v_receiver_wallet.wallet_id THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Impossible de transférer vers votre propre compte'
    );
  END IF;
  
  IF v_sender_wallet.wallet_status != 'active' THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Wallet expéditeur inactif'
    );
  END IF;
  
  IF v_receiver_wallet.wallet_status != 'active' THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Wallet destinataire inactif'
    );
  END IF;
  
  -- Calculer frais
  v_fee_percent := get_transfer_fee_percent();
  v_fee_amount := ROUND((p_amount * v_fee_percent) / 100, 0);
  v_total_debit := p_amount + v_fee_amount;
  
  IF v_sender_wallet.balance < v_total_debit THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Solde insuffisant'
    );
  END IF;
  
  -- Générer référence transaction
  v_transaction_ref := 'TRF-' || EXTRACT(EPOCH FROM NOW())::BIGINT || '-' || FLOOR(RANDOM() * 1000)::INT;
  
  -- Débiter l'expéditeur selon le type
  IF v_sender_wallet.wallet_type = 'bureau' THEN
    UPDATE bureau_wallets
    SET 
      balance = balance - v_total_debit,
      updated_at = NOW()
    WHERE id = v_sender_wallet.wallet_id;
    
    -- Transaction bureau
    INSERT INTO bureau_transactions (
      bureau_id, type, amount, description, status, reference, date
    ) VALUES (
      v_sender_wallet.owner_id,
      'debit',
      v_total_debit,
      COALESCE(p_description, 'Transfert vers ' || p_receiver_code),
      'completed',
      v_transaction_ref,
      CURRENT_DATE
    );
  ELSIF v_sender_wallet.wallet_type = 'agent' THEN
    UPDATE agent_wallets
    SET 
      balance = balance - v_total_debit,
      updated_at = NOW()
    WHERE id = v_sender_wallet.wallet_id;
  ELSE
    UPDATE wallets
    SET 
      balance = balance - v_total_debit,
      updated_at = NOW()
    WHERE id = v_sender_wallet.wallet_id;
  END IF;
  
  -- Crédit transaction pour l'expéditeur
  INSERT INTO wallet_transactions (
    transaction_id,
    transaction_type,
    amount,
    net_amount,
    fee,
    currency,
    status,
    description,
    sender_wallet_id,
    receiver_wallet_id,
    metadata
  ) VALUES (
    v_transaction_ref || '-OUT',
    'transfer_out',
    -p_amount,
    -p_amount,
    v_fee_amount,
    p_currency,
    'completed',
    COALESCE(p_description, 'Transfert vers ' || p_receiver_code),
    v_sender_wallet.wallet_id,
    v_receiver_wallet.wallet_id,
    jsonb_build_object(
      'sender_type', v_sender_wallet.wallet_type,
      'receiver_type', v_receiver_wallet.wallet_type,
      'sender_code', p_sender_code,
      'receiver_code', p_receiver_code
    )
  );
  
  -- Créditer le destinataire selon le type
  IF v_receiver_wallet.wallet_type = 'bureau' THEN
    UPDATE bureau_wallets
    SET 
      balance = balance + p_amount,
      updated_at = NOW()
    WHERE id = v_receiver_wallet.wallet_id;
    
    -- Transaction bureau
    INSERT INTO bureau_transactions (
      bureau_id, type, amount, description, status, reference, date
    ) VALUES (
      v_receiver_wallet.owner_id,
      'credit',
      p_amount,
      COALESCE(p_description, 'Transfert reçu de ' || p_sender_code),
      'completed',
      v_transaction_ref,
      CURRENT_DATE
    );
  ELSIF v_receiver_wallet.wallet_type = 'agent' THEN
    UPDATE agent_wallets
    SET 
      balance = balance + p_amount,
      updated_at = NOW()
    WHERE id = v_receiver_wallet.wallet_id;
  ELSE
    UPDATE wallets
    SET 
      balance = balance + p_amount,
      updated_at = NOW()
    WHERE id = v_receiver_wallet.wallet_id;
  END IF;
  
  -- Crédit transaction pour le destinataire
  INSERT INTO wallet_transactions (
    transaction_id,
    transaction_type,
    amount,
    net_amount,
    fee,
    currency,
    status,
    description,
    sender_wallet_id,
    receiver_wallet_id,
    metadata
  ) VALUES (
    v_transaction_ref || '-IN',
    'transfer_in',
    p_amount,
    p_amount,
    0,
    p_currency,
    'completed',
    COALESCE(p_description, 'Transfert reçu de ' || p_sender_code),
    v_sender_wallet.wallet_id,
    v_receiver_wallet.wallet_id,
    jsonb_build_object(
      'sender_type', v_sender_wallet.wallet_type,
      'receiver_type', v_receiver_wallet.wallet_type,
      'sender_code', p_sender_code,
      'receiver_code', p_receiver_code
    )
  );
  
  -- Retourner succès
  RETURN json_build_object(
    'success', true,
    'transaction_ref', v_transaction_ref,
    'amount', p_amount,
    'fee', v_fee_amount,
    'total_debit', v_total_debit,
    'message', 'Transfert effectué avec succès'
  );
  
EXCEPTION
  WHEN OTHERS THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Erreur lors du transfert: ' || SQLERRM
    );
END;
$$;

COMMENT ON FUNCTION execute_wallet_transfer_by_code(TEXT, TEXT, NUMERIC, VARCHAR, TEXT) IS 'Exécute un transfert entre wallets (bureaux, agents, users)';

-- Permissions
GRANT EXECUTE ON FUNCTION execute_wallet_transfer_by_code(TEXT, TEXT, NUMERIC, VARCHAR, TEXT) TO authenticated;
