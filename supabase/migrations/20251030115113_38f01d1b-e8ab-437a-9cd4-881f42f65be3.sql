-- Supprimer l'ancienne fonction et recréer avec enregistrement des revenus
DROP FUNCTION IF EXISTS process_wallet_transaction(TEXT, TEXT, DECIMAL, TEXT, TEXT);

CREATE FUNCTION process_wallet_transaction(
  p_sender_email TEXT,
  p_receiver_email TEXT,
  p_amount DECIMAL,
  p_currency TEXT DEFAULT 'GNF',
  p_description TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sender_user_id UUID;
  v_receiver_user_id UUID;
  v_sender_wallet_id UUID;
  v_receiver_wallet_id UUID;
  v_sender_balance DECIMAL;
  v_fee_percent DECIMAL := 1.5;
  v_fee_amount DECIMAL;
  v_total_debit DECIMAL;
  v_transaction_id UUID;
  v_result JSONB;
BEGIN
  -- Récupérer le taux de frais depuis la configuration
  BEGIN
    SELECT COALESCE(setting_value::DECIMAL, 1.5) INTO v_fee_percent
    FROM system_settings
    WHERE setting_key = 'transfer_fee_percent';
  EXCEPTION WHEN OTHERS THEN
    v_fee_percent := 1.5;
  END;

  -- Calculer les frais
  v_fee_amount := ROUND(p_amount * v_fee_percent / 100, 2);
  v_total_debit := p_amount + v_fee_amount;

  -- Récupérer les IDs utilisateurs
  SELECT id INTO v_sender_user_id
  FROM auth.users
  WHERE email = p_sender_email;

  SELECT id INTO v_receiver_user_id
  FROM auth.users
  WHERE email = p_receiver_email;

  IF v_sender_user_id IS NULL THEN
    RAISE EXCEPTION 'Expéditeur introuvable';
  END IF;

  IF v_receiver_user_id IS NULL THEN
    RAISE EXCEPTION 'Destinataire introuvable';
  END IF;

  IF v_sender_user_id = v_receiver_user_id THEN
    RAISE EXCEPTION 'Impossible de transférer à soi-même';
  END IF;

  -- Récupérer les wallets
  SELECT id, balance INTO v_sender_wallet_id, v_sender_balance
  FROM wallets
  WHERE user_id = v_sender_user_id AND currency = p_currency
  FOR UPDATE;

  SELECT id INTO v_receiver_wallet_id
  FROM wallets
  WHERE user_id = v_receiver_user_id AND currency = p_currency
  FOR UPDATE;

  IF v_sender_wallet_id IS NULL THEN
    RAISE EXCEPTION 'Wallet expéditeur introuvable';
  END IF;

  IF v_receiver_wallet_id IS NULL THEN
    RAISE EXCEPTION 'Wallet destinataire introuvable';
  END IF;

  -- Vérifier le solde
  IF v_sender_balance < v_total_debit THEN
    RAISE EXCEPTION 'Solde insuffisant';
  END IF;

  -- Débiter l'expéditeur (montant + frais)
  UPDATE wallets
  SET balance = balance - v_total_debit,
      updated_at = now()
  WHERE id = v_sender_wallet_id;

  -- Créditer le destinataire (montant sans frais)
  UPDATE wallets
  SET balance = balance + p_amount,
      updated_at = now()
  WHERE id = v_receiver_wallet_id;

  -- Créer la transaction
  INSERT INTO enhanced_transactions (
    sender_id,
    receiver_id,
    amount,
    currency,
    method,
    status,
    description,
    metadata
  )
  VALUES (
    v_sender_user_id,
    v_receiver_user_id,
    p_amount,
    p_currency,
    'wallet',
    'completed',
    COALESCE(p_description, 'Transfert wallet'),
    jsonb_build_object(
      'fee_percent', v_fee_percent,
      'fee_amount', v_fee_amount,
      'total_debit', v_total_debit,
      'amount_received', p_amount,
      'sender_email', p_sender_email,
      'receiver_email', p_receiver_email
    )
  )
  RETURNING id INTO v_transaction_id;

  -- Enregistrer le revenu de la plateforme
  PERFORM record_platform_revenue(
    'transfer_fee',
    v_fee_amount,
    v_transaction_id,
    jsonb_build_object(
      'sender_email', p_sender_email,
      'receiver_email', p_receiver_email,
      'transfer_amount', p_amount,
      'fee_percent', v_fee_percent
    )
  );

  -- Résultat
  v_result := jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'amount', p_amount,
    'fee_amount', v_fee_amount,
    'total_debit', v_total_debit,
    'amount_received', p_amount,
    'sender_new_balance', (SELECT balance FROM wallets WHERE id = v_sender_wallet_id),
    'receiver_new_balance', (SELECT balance FROM wallets WHERE id = v_receiver_wallet_id)
  );

  RETURN v_result;

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'Erreur transaction: %', SQLERRM;
END;
$$;