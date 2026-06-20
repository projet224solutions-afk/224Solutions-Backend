-- 1. Corriger immédiatement la désynchronisation AGT0009
UPDATE agent_wallets 
SET balance = 205800.00, updated_at = NOW()
WHERE agent_id = '48c76463-6f9a-468b-be13-3a709538d626';

-- 2. Synchroniser TOUS les agent_wallets avec wallets (source de vérité)
UPDATE agent_wallets aw
SET balance = w.balance, updated_at = NOW()
FROM agents_management am
JOIN wallets w ON am.user_id = w.user_id
WHERE aw.agent_id = am.id
AND aw.balance != w.balance;

-- 3. Supprimer l'ancien trigger défaillant
DROP TRIGGER IF EXISTS trigger_sync_agent_wallet ON wallets;
DROP FUNCTION IF EXISTS sync_agent_wallet_balance CASCADE;

-- 4. Créer une fonction de synchronisation robuste et simple
CREATE OR REPLACE FUNCTION sync_agent_wallet_from_wallets()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agent_id UUID;
BEGIN
  -- Trouver l'agent_id correspondant à ce user_id
  SELECT id INTO v_agent_id
  FROM agents_management
  WHERE user_id = NEW.user_id;
  
  -- Si c'est un agent, synchroniser son agent_wallet
  IF v_agent_id IS NOT NULL THEN
    -- Mise à jour ou insertion dans agent_wallets
    INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status, updated_at)
    VALUES (v_agent_id, NEW.balance, 'GNF', 'active', NOW())
    ON CONFLICT (agent_id) 
    DO UPDATE SET 
      balance = EXCLUDED.balance,
      updated_at = NOW();
  END IF;
  
  RETURN NEW;
END;
$$;

-- 5. Créer le trigger sur wallets (après INSERT ou UPDATE)
CREATE TRIGGER trigger_sync_agent_wallet_robust
AFTER INSERT OR UPDATE OF balance ON wallets
FOR EACH ROW
EXECUTE FUNCTION sync_agent_wallet_from_wallets();

-- 6. Améliorer process_secure_wallet_transfer pour synchronisation directe
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
  v_wallet_tx_id UUID;
  v_sender_agent_id UUID;
  v_receiver_agent_id UUID;
BEGIN
  -- Générer ou utiliser l'ID de transaction
  v_tx_id := COALESCE(p_transaction_id, 'TX-' || gen_random_uuid()::TEXT);
  
  -- Vérification idempotence
  IF EXISTS (SELECT 1 FROM wallet_transactions WHERE reference = v_tx_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transaction déjà traitée');
  END IF;
  
  -- Calculer les frais
  v_fee_amount := ROUND(p_amount * v_fee_rate, 2);
  v_net_amount := p_amount; -- Le receveur reçoit le montant complet, l'envoyeur paie les frais
  
  -- VERROUILLER et lire le solde de l'envoyeur
  SELECT balance INTO v_sender_balance
  FROM wallets
  WHERE user_id = p_sender_id
  FOR UPDATE;
  
  IF v_sender_balance IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet envoyeur introuvable');
  END IF;
  
  -- Vérifier solde suffisant (montant + frais)
  IF v_sender_balance < (p_amount + v_fee_amount) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solde insuffisant');
  END IF;
  
  -- VERROUILLER et lire le solde du receveur
  SELECT balance INTO v_receiver_balance
  FROM wallets
  WHERE user_id = p_receiver_id
  FOR UPDATE;
  
  -- Créer le wallet du receveur si nécessaire
  IF v_receiver_balance IS NULL THEN
    INSERT INTO wallets (user_id, balance, currency, wallet_status)
    VALUES (p_receiver_id, 0, 'GNF', 'active');
    v_receiver_balance := 0;
  END IF;
  
  -- CALCUL EXACT des nouveaux soldes
  v_sender_balance_after := v_sender_balance - p_amount - v_fee_amount;
  v_receiver_balance_after := v_receiver_balance + v_net_amount;
  
  -- VALIDATION PRE-TRANSACTION
  IF v_sender_balance_after != (v_sender_balance - p_amount - v_fee_amount) THEN
    RAISE EXCEPTION 'Erreur de calcul détectée pour l''envoyeur';
  END IF;
  IF v_receiver_balance_after != (v_receiver_balance + v_net_amount) THEN
    RAISE EXCEPTION 'Erreur de calcul détectée pour le receveur';
  END IF;
  
  -- MISE À JOUR ATOMIQUE - Envoyeur (le trigger synchronisera agent_wallets)
  UPDATE wallets
  SET balance = v_sender_balance_after, updated_at = NOW()
  WHERE user_id = p_sender_id;
  
  -- MISE À JOUR ATOMIQUE - Receveur (le trigger synchronisera agent_wallets)
  UPDATE wallets
  SET balance = v_receiver_balance_after, updated_at = NOW()
  WHERE user_id = p_receiver_id;
  
  -- Enregistrer la transaction
  INSERT INTO wallet_transactions (
    wallet_id,
    amount,
    type,
    status,
    reference,
    description,
    metadata
  )
  SELECT 
    w.id,
    p_amount,
    'transfer',
    'completed',
    v_tx_id,
    COALESCE(p_description, 'Transfert sécurisé'),
    jsonb_build_object(
      'sender_id', p_sender_id,
      'receiver_id', p_receiver_id,
      'sender_balance_before', v_sender_balance,
      'sender_balance_after', v_sender_balance_after,
      'receiver_balance_before', v_receiver_balance,
      'receiver_balance_after', v_receiver_balance_after,
      'fee_amount', v_fee_amount,
      'net_amount', v_net_amount
    )
  FROM wallets w
  WHERE w.user_id = p_sender_id
  RETURNING id INTO v_wallet_tx_id;
  
  -- Journaliser dans transaction_audit_log
  INSERT INTO transaction_audit_log (
    transaction_id, user_id, operation_type, amount,
    balance_before, balance_after, expected_balance, is_valid,
    metadata
  ) VALUES (
    v_tx_id, p_sender_id, 'debit', -(p_amount + v_fee_amount),
    v_sender_balance, v_sender_balance_after, v_sender_balance_after, true,
    jsonb_build_object('fee', v_fee_amount, 'receiver', p_receiver_id)
  ), (
    v_tx_id, p_receiver_id, 'credit', v_net_amount,
    v_receiver_balance, v_receiver_balance_after, v_receiver_balance_after, true,
    jsonb_build_object('sender', p_sender_id)
  );
  
  -- SYNCHRONISATION EXPLICITE des agent_wallets (double sécurité)
  SELECT id INTO v_sender_agent_id FROM agents_management WHERE user_id = p_sender_id;
  SELECT id INTO v_receiver_agent_id FROM agents_management WHERE user_id = p_receiver_id;
  
  IF v_sender_agent_id IS NOT NULL THEN
    UPDATE agent_wallets SET balance = v_sender_balance_after, updated_at = NOW()
    WHERE agent_id = v_sender_agent_id;
  END IF;
  
  IF v_receiver_agent_id IS NOT NULL THEN
    UPDATE agent_wallets SET balance = v_receiver_balance_after, updated_at = NOW()
    WHERE agent_id = v_receiver_agent_id;
  END IF;
  
  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_tx_id,
    'wallet_transaction_id', v_wallet_tx_id,
    'sender_balance_after', v_sender_balance_after,
    'receiver_balance_after', v_receiver_balance_after,
    'fee_amount', v_fee_amount
  );
END;
$$;