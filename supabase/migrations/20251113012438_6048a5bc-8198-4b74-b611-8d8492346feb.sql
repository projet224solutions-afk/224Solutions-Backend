-- Correction finale de process_wallet_transfer_with_fees pour utiliser wallet_status
CREATE OR REPLACE FUNCTION process_wallet_transfer_with_fees(
  p_sender_code TEXT,
  p_receiver_code TEXT,
  p_amount NUMERIC,
  p_currency VARCHAR DEFAULT 'GNF',
  p_description TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sender_id UUID;
  v_receiver_id UUID;
  v_fee_percent NUMERIC;
  v_fee_amount NUMERIC;
  v_total_debit NUMERIC;
  v_transaction_id UUID;
  v_sender_balance NUMERIC;
BEGIN
  -- Trouver l'expéditeur
  v_sender_id := find_user_by_code(p_sender_code);
  IF v_sender_id IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Expéditeur introuvable');
  END IF;
  
  -- Trouver le destinataire
  v_receiver_id := find_user_by_code(p_receiver_code);
  IF v_receiver_id IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Destinataire introuvable');
  END IF;
  
  -- Vérifier que ce ne sont pas la même personne
  IF v_sender_id = v_receiver_id THEN
    RETURN json_build_object('success', false, 'error', 'Auto-transfert impossible');
  END IF;
  
  -- Calculer les frais
  v_fee_percent := get_transfer_fee_percent();
  v_fee_amount := ROUND((p_amount * v_fee_percent) / 100, 0);
  v_total_debit := p_amount + v_fee_amount;
  
  -- Vérifier le solde
  SELECT balance INTO v_sender_balance 
  FROM wallets 
  WHERE user_id = v_sender_id AND currency = p_currency;
  
  IF v_sender_balance IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Wallet expéditeur introuvable');
  END IF;
  
  IF v_sender_balance < v_total_debit THEN
    RETURN json_build_object(
      'success', false, 
      'error', 'Solde insuffisant',
      'required', v_total_debit,
      'current', v_sender_balance
    );
  END IF;
  
  -- Créer la transaction
  INSERT INTO enhanced_transactions (
    sender_id, 
    receiver_id, 
    amount, 
    currency, 
    method, 
    metadata, 
    status
  )
  VALUES (
    v_sender_id, 
    v_receiver_id, 
    p_amount, 
    p_currency, 
    'wallet',
    jsonb_build_object(
      'description', COALESCE(p_description, ''),
      'fee_amount', v_fee_amount,
      'fee_percent', v_fee_percent,
      'total_debit', v_total_debit
    ),
    'pending'
  )
  RETURNING id INTO v_transaction_id;
  
  -- Débiter l'expéditeur (montant + frais)
  UPDATE wallets 
  SET balance = balance - v_total_debit, updated_at = now()
  WHERE user_id = v_sender_id AND currency = p_currency;
  
  -- Créditer le destinataire (montant seulement, sans frais)
  -- CORRECTION: utiliser wallet_status au lieu de status
  INSERT INTO wallets (user_id, balance, currency, wallet_status)
  VALUES (v_receiver_id, p_amount, p_currency, 'active')
  ON CONFLICT (user_id, currency) 
  DO UPDATE SET 
    balance = wallets.balance + p_amount, 
    updated_at = now();
  
  -- Marquer comme complétée
  UPDATE enhanced_transactions 
  SET status = 'completed', updated_at = now()
  WHERE id = v_transaction_id;
  
  RETURN json_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'amount', p_amount,
    'fee_amount', v_fee_amount,
    'total_debit', v_total_debit
  );
END;
$$;