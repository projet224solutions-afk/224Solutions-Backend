-- Corriger les fonctions existantes avec search_path manquant
CREATE OR REPLACE FUNCTION generate_transaction_custom_id()
RETURNS TEXT 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  letters TEXT := '';
  numbers TEXT := '';
  i INTEGER;
  new_custom_id TEXT;
BEGIN
  -- Générer 3 lettres aléatoires
  FOR i IN 1..3 LOOP
    letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
  END LOOP;
  
  -- Générer 4 chiffres aléatoires
  FOR i IN 1..4 LOOP
    numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
  END LOOP;
  
  new_custom_id := letters || numbers;
  
  -- Vérifier l'unicité
  WHILE EXISTS (SELECT 1 FROM enhanced_transactions WHERE custom_id = new_custom_id) LOOP
    letters := '';
    numbers := '';
    FOR i IN 1..3 LOOP
      letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
    END LOOP;
    FOR i IN 1..4 LOOP
      numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
    END LOOP;
    new_custom_id := letters || numbers;
  END LOOP;
  
  RETURN new_custom_id;
END;
$$;

-- Corriger la fonction process_wallet_transaction
CREATE OR REPLACE FUNCTION process_wallet_transaction(
  p_sender_id UUID,
  p_receiver_id UUID,
  p_amount NUMERIC,
  p_currency VARCHAR DEFAULT 'GNF',
  p_description TEXT DEFAULT NULL
)
RETURNS UUID 
LANGUAGE plpgsql 
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  transaction_id UUID;
  sender_wallet_balance NUMERIC;
BEGIN
  -- Vérifier le solde de l'expéditeur
  SELECT balance INTO sender_wallet_balance 
  FROM wallets 
  WHERE user_id = p_sender_id AND currency = p_currency;
  
  IF sender_wallet_balance IS NULL THEN
    RAISE EXCEPTION 'Wallet non trouvé pour l''expéditeur';
  END IF;
  
  IF sender_wallet_balance < p_amount THEN
    RAISE EXCEPTION 'Solde insuffisant';
  END IF;
  
  -- Créer la transaction
  INSERT INTO enhanced_transactions (sender_id, receiver_id, amount, currency, method, metadata)
  VALUES (p_sender_id, p_receiver_id, p_amount, p_currency, 'wallet', 
          jsonb_build_object('description', COALESCE(p_description, '')))
  RETURNING id INTO transaction_id;
  
  -- Débiter l'expéditeur
  UPDATE wallets 
  SET balance = balance - p_amount, updated_at = now()
  WHERE user_id = p_sender_id AND currency = p_currency;
  
  -- Créditer le destinataire (créer wallet si n'existe pas)
  INSERT INTO wallets (user_id, balance, currency)
  VALUES (p_receiver_id, p_amount, p_currency)
  ON CONFLICT (user_id, currency) 
  DO UPDATE SET balance = wallets.balance + p_amount, updated_at = now();
  
  -- Marquer comme complétée
  UPDATE enhanced_transactions 
  SET status = 'completed', updated_at = now()
  WHERE id = transaction_id;
  
  RETURN transaction_id;
END;
$$;