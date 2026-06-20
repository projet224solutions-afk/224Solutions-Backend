-- Migration complète pour corriger toutes les références à 'status' dans wallets

-- 1. Supprimer les anciens index qui utilisent 'status'
DROP INDEX IF EXISTS idx_wallets_status;

-- 2. Recréer les index avec wallet_status
CREATE INDEX IF NOT EXISTS idx_wallets_wallet_status ON wallets(wallet_status);

-- 3. Corriger la fonction auto_create_wallet_and_card si elle existe
DROP FUNCTION IF EXISTS auto_create_wallet_and_card() CASCADE;
CREATE OR REPLACE FUNCTION auto_create_wallet_and_card()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    new_wallet_id UUID;
    card_number VARCHAR(16);
    cvv VARCHAR(3);
    expiry_year VARCHAR(4);
    expiry_month VARCHAR(2);
BEGIN
    -- Créer le wallet automatiquement
    INSERT INTO wallets (user_id, balance, currency, wallet_status)
    VALUES (NEW.id, 0.00, 'GNF', 'active')
    ON CONFLICT (user_id, currency) DO NOTHING
    RETURNING id INTO new_wallet_id;
    
    RETURN NEW;
END;
$$;

-- 4. Corriger toutes les autres fonctions qui pourraient utiliser status
-- Fonction process_wallet_transfer
DROP FUNCTION IF EXISTS process_wallet_transfer(uuid, uuid, numeric, text, text) CASCADE;
CREATE OR REPLACE FUNCTION process_wallet_transfer(
  p_sender_id uuid,
  p_receiver_id uuid,
  p_amount numeric,
  p_description text DEFAULT NULL,
  p_currency text DEFAULT 'GNF'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sender_wallet_id uuid;
  v_receiver_wallet_id uuid;
  v_transaction_id uuid;
  v_sender_balance numeric;
BEGIN
  -- Vérifier que le montant est positif
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Le montant doit être positif');
  END IF;

  -- Récupérer ou créer le wallet expéditeur
  SELECT id, balance INTO v_sender_wallet_id, v_sender_balance
  FROM wallets
  WHERE user_id = p_sender_id AND currency = p_currency;
  
  IF v_sender_wallet_id IS NULL THEN
    INSERT INTO wallets (user_id, balance, currency, wallet_status)
    VALUES (p_sender_id, 0, p_currency, 'active')
    RETURNING id, balance INTO v_sender_wallet_id, v_sender_balance;
  END IF;

  -- Vérifier le solde
  IF v_sender_balance < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solde insuffisant');
  END IF;

  -- Récupérer ou créer le wallet destinataire
  SELECT id INTO v_receiver_wallet_id
  FROM wallets
  WHERE user_id = p_receiver_id AND currency = p_currency;
  
  IF v_receiver_wallet_id IS NULL THEN
    INSERT INTO wallets (user_id, balance, currency, wallet_status)
    VALUES (p_receiver_id, 0, p_currency, 'active')
    RETURNING id INTO v_receiver_wallet_id;
  END IF;

  -- Débiter l'expéditeur
  UPDATE wallets
  SET balance = balance - p_amount,
      updated_at = now()
  WHERE id = v_sender_wallet_id;

  -- Créditer le destinataire
  UPDATE wallets
  SET balance = balance + p_amount,
      updated_at = now()
  WHERE id = v_receiver_wallet_id;

  -- Créer la transaction
  INSERT INTO wallet_transactions (
    from_wallet_id,
    to_wallet_id,
    amount,
    transaction_type,
    status,
    description
  ) VALUES (
    v_sender_wallet_id,
    v_receiver_wallet_id,
    p_amount,
    'transfer',
    'completed',
    COALESCE(p_description, 'Transfert entre wallets')
  ) RETURNING id INTO v_transaction_id;

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'sender_wallet', v_sender_wallet_id,
    'receiver_wallet', v_receiver_wallet_id,
    'amount', p_amount
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;