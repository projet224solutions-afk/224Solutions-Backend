-- ============================================
-- SYSTÈME DE TRANSFERT WALLET UNIFIÉ
-- Normalise les IDs et crée des fonctions complètes
-- ============================================

-- 1. Fonction pour trouver un user_id depuis n'importe quel type d'ID
CREATE OR REPLACE FUNCTION find_user_by_code(p_code TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  -- Chercher dans user_ids (custom_id)
  SELECT user_id INTO v_user_id
  FROM user_ids
  WHERE custom_id = UPPER(p_code)
  LIMIT 1;
  
  IF v_user_id IS NOT NULL THEN
    RETURN v_user_id;
  END IF;
  
  -- Chercher dans profiles (custom_id)
  SELECT id INTO v_user_id
  FROM profiles
  WHERE custom_id = UPPER(p_code)
  LIMIT 1;
  
  IF v_user_id IS NOT NULL THEN
    RETURN v_user_id;
  END IF;
  
  -- Chercher dans profiles (public_id)
  SELECT id INTO v_user_id
  FROM profiles
  WHERE public_id = UPPER(p_code)
  LIMIT 1;
  
  RETURN v_user_id;
END;
$$;

-- 2. Fonction améliorée pour prévisualiser le transfert avec custom_id
CREATE OR REPLACE FUNCTION preview_wallet_transfer_by_code(
  p_sender_code TEXT,
  p_receiver_code TEXT,
  p_amount NUMERIC,
  p_currency VARCHAR DEFAULT 'GNF'
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_sender_id UUID;
  v_receiver_id UUID;
  v_sender_info JSONB;
  v_receiver_info JSONB;
  v_fee_percent NUMERIC;
  v_fee_amount NUMERIC;
  v_total_debit NUMERIC;
  v_sender_balance NUMERIC;
  v_sender_status VARCHAR;
BEGIN
  -- Trouver l'expéditeur
  v_sender_id := find_user_by_code(p_sender_code);
  
  IF v_sender_id IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Expéditeur introuvable: ' || p_sender_code
    );
  END IF;
  
  -- Trouver le destinataire
  v_receiver_id := find_user_by_code(p_receiver_code);
  
  IF v_receiver_id IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Destinataire introuvable: ' || p_receiver_code
    );
  END IF;
  
  -- Vérifier que ce ne sont pas la même personne
  IF v_sender_id = v_receiver_id THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Impossible de transférer vers votre propre compte'
    );
  END IF;
  
  -- Récupérer les infos de l'expéditeur
  SELECT jsonb_build_object(
    'id', p.id,
    'name', COALESCE(p.first_name || ' ' || p.last_name, 'Non renseigné'),
    'email', COALESCE(p.email, 'Non renseigné'),
    'phone', COALESCE(p.phone, 'Non renseigné'),
    'custom_id', COALESCE(p.custom_id, p.public_id)
  ) INTO v_sender_info
  FROM profiles p
  WHERE p.id = v_sender_id;
  
  -- Récupérer les infos du destinataire
  SELECT jsonb_build_object(
    'id', p.id,
    'name', COALESCE(p.first_name || ' ' || p.last_name, 'Non renseigné'),
    'email', COALESCE(p.email, 'Non renseigné'),
    'phone', COALESCE(p.phone, 'Non renseigné'),
    'custom_id', COALESCE(p.custom_id, p.public_id)
  ) INTO v_receiver_info
  FROM profiles p
  WHERE p.id = v_receiver_id;
  
  -- Obtenir le taux de commission
  v_fee_percent := get_transfer_fee_percent();
  
  -- Calculer les frais
  v_fee_amount := ROUND((p_amount * v_fee_percent) / 100, 0);
  v_total_debit := p_amount + v_fee_amount;
  
  -- Vérifier le wallet de l'expéditeur
  SELECT balance, status INTO v_sender_balance, v_sender_status
  FROM wallets
  WHERE user_id = v_sender_id AND currency = p_currency;
  
  IF v_sender_balance IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Wallet expéditeur introuvable'
    );
  END IF;
  
  IF v_sender_status != 'active' THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Wallet expéditeur inactif'
    );
  END IF;
  
  -- Vérifier le solde
  IF v_sender_balance < v_total_debit THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Solde insuffisant',
      'current_balance', v_sender_balance,
      'required', v_total_debit,
      'shortage', v_total_debit - v_sender_balance
    );
  END IF;
  
  -- Retourner la prévisualisation complète
  RETURN json_build_object(
    'success', true,
    'sender', v_sender_info,
    'receiver', v_receiver_info,
    'amount', p_amount,
    'fee_percent', v_fee_percent,
    'fee_amount', v_fee_amount,
    'total_debit', v_total_debit,
    'amount_received', p_amount,
    'current_balance', v_sender_balance,
    'balance_after', v_sender_balance - v_total_debit
  );
END;
$$;

-- 3. Fonction complète de transfert avec frais
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
  INSERT INTO wallets (user_id, balance, currency, status)
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

-- Accorder les permissions
GRANT EXECUTE ON FUNCTION find_user_by_code(TEXT) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION preview_wallet_transfer_by_code(TEXT, TEXT, NUMERIC, VARCHAR) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION process_wallet_transfer_with_fees(TEXT, TEXT, NUMERIC, VARCHAR, TEXT) TO authenticated, anon;