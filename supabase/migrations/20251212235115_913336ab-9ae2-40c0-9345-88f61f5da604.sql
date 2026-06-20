-- Corriger la fonction de transfert pour enregistrer les transactions des DEUX côtés
-- et intégrer correctement avec le système bancaire

CREATE OR REPLACE FUNCTION process_secure_wallet_transfer(
  p_sender_id UUID,
  p_receiver_id UUID,
  p_amount NUMERIC,
  p_description TEXT DEFAULT NULL,
  p_transaction_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sender_balance NUMERIC;
  v_receiver_balance NUMERIC;
  v_fee_rate NUMERIC := 0.01;
  v_fee_amount NUMERIC;
  v_net_amount NUMERIC;
  v_sender_balance_after NUMERIC;
  v_receiver_balance_after NUMERIC;
  v_tx_id TEXT;
  v_sender_wallet_id UUID;
  v_receiver_wallet_id UUID;
  v_sender_wallet_tx_id UUID;
  v_receiver_wallet_tx_id UUID;
BEGIN
  -- Générer un ID de transaction unique si non fourni
  v_tx_id := COALESCE(p_transaction_id, 'TXN-' || EXTRACT(EPOCH FROM now())::TEXT || '-' || FLOOR(RANDOM() * 10000)::TEXT);

  -- Vérifier l'idempotence
  IF EXISTS (SELECT 1 FROM wallet_transactions WHERE reference = v_tx_id) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Transaction déjà traitée',
      'transaction_id', v_tx_id
    );
  END IF;

  -- Valider le montant
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Montant invalide');
  END IF;

  -- Vérifier que sender != receiver
  IF p_sender_id = p_receiver_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Impossible de transférer vers soi-même');
  END IF;

  -- Calculer les frais
  v_fee_amount := ROUND(p_amount * v_fee_rate, 2);
  v_net_amount := p_amount - v_fee_amount;

  -- Récupérer le wallet et solde de l'expéditeur avec verrouillage
  SELECT id, balance INTO v_sender_wallet_id, v_sender_balance
  FROM wallets 
  WHERE user_id = p_sender_id
  FOR UPDATE;

  IF v_sender_wallet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet expéditeur non trouvé');
  END IF;

  -- Vérifier le solde suffisant
  IF v_sender_balance < p_amount THEN
    RETURN jsonb_build_object(
      'success', false, 
      'error', 'Solde insuffisant (' || v_sender_balance || ' GNF disponible, ' || p_amount || ' GNF requis)'
    );
  END IF;

  -- Récupérer ou créer le wallet du destinataire
  SELECT id, balance INTO v_receiver_wallet_id, v_receiver_balance
  FROM wallets 
  WHERE user_id = p_receiver_id
  FOR UPDATE;

  IF v_receiver_wallet_id IS NULL THEN
    -- Créer le wallet du destinataire s'il n'existe pas
    INSERT INTO wallets (user_id, balance, currency, status)
    VALUES (p_receiver_id, 0, 'GNF', 'active')
    RETURNING id, balance INTO v_receiver_wallet_id, v_receiver_balance;
  END IF;

  -- PHASE 1: Calculer les nouveaux soldes
  v_sender_balance_after := v_sender_balance - p_amount;
  v_receiver_balance_after := v_receiver_balance + v_net_amount;

  -- PHASE 2: Débiter l'expéditeur
  UPDATE wallets 
  SET balance = v_sender_balance_after, updated_at = now()
  WHERE id = v_sender_wallet_id;

  -- Créditer le destinataire
  UPDATE wallets 
  SET balance = v_receiver_balance_after, updated_at = now()
  WHERE id = v_receiver_wallet_id;

  -- PHASE 3: Enregistrer la transaction CÔTÉ EXPÉDITEUR (débit)
  INSERT INTO wallet_transactions (
    wallet_id,
    sender_wallet_id,
    receiver_wallet_id,
    amount,
    fee,
    net_amount,
    currency,
    transaction_type,
    status,
    transaction_id,
    description,
    metadata
  )
  VALUES (
    v_sender_wallet_id,
    v_sender_wallet_id,
    v_receiver_wallet_id,
    p_amount,
    v_fee_amount,
    v_net_amount,
    'GNF',
    'transfer_out',
    'completed',
    v_tx_id,
    COALESCE(p_description, 'Transfert sortant'),
    jsonb_build_object(
      'sender_id', p_sender_id,
      'receiver_id', p_receiver_id,
      'sender_balance_before', v_sender_balance,
      'sender_balance_after', v_sender_balance_after,
      'fee_amount', v_fee_amount,
      'net_amount', v_net_amount
    )
  )
  RETURNING id INTO v_sender_wallet_tx_id;

  -- ENREGISTRER LA TRANSACTION CÔTÉ DESTINATAIRE (crédit)
  INSERT INTO wallet_transactions (
    wallet_id,
    sender_wallet_id,
    receiver_wallet_id,
    amount,
    fee,
    net_amount,
    currency,
    transaction_type,
    status,
    transaction_id,
    description,
    metadata
  )
  VALUES (
    v_receiver_wallet_id,
    v_sender_wallet_id,
    v_receiver_wallet_id,
    v_net_amount,
    0,
    v_net_amount,
    'GNF',
    'transfer_in',
    'completed',
    v_tx_id || '-R',
    COALESCE(p_description, 'Transfert reçu'),
    jsonb_build_object(
      'sender_id', p_sender_id,
      'receiver_id', p_receiver_id,
      'receiver_balance_before', v_receiver_balance,
      'receiver_balance_after', v_receiver_balance_after,
      'original_amount', p_amount,
      'fee_deducted', v_fee_amount,
      'net_received', v_net_amount
    )
  )
  RETURNING id INTO v_receiver_wallet_tx_id;

  -- Synchroniser agent_wallets si applicable
  UPDATE agent_wallets 
  SET balance = v_sender_balance_after, updated_at = now()
  WHERE agent_id IN (SELECT id FROM agents_management WHERE user_id = p_sender_id);

  UPDATE agent_wallets 
  SET balance = v_receiver_balance_after, updated_at = now()
  WHERE agent_id IN (SELECT id FROM agents_management WHERE user_id = p_receiver_id);

  -- Enregistrer dans le journal d'audit
  INSERT INTO transaction_audit_log (
    transaction_id,
    action,
    actor_id,
    actor_type,
    old_value,
    new_value,
    metadata
  )
  VALUES (
    v_sender_wallet_tx_id,
    'TRANSFER_COMPLETED',
    p_sender_id,
    'user',
    jsonb_build_object('sender_balance', v_sender_balance, 'receiver_balance', v_receiver_balance),
    jsonb_build_object('sender_balance', v_sender_balance_after, 'receiver_balance', v_receiver_balance_after),
    jsonb_build_object(
      'amount', p_amount,
      'fee', v_fee_amount,
      'net', v_net_amount,
      'tx_id', v_tx_id
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_tx_id,
    'amount', p_amount,
    'fee_amount', v_fee_amount,
    'net_amount', v_net_amount,
    'sender_balance_after', v_sender_balance_after,
    'receiver_balance_after', v_receiver_balance_after
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'transaction_id', v_tx_id
  );
END;
$$;