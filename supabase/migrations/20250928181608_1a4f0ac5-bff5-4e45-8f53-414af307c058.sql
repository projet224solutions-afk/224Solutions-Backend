-- Fonction pour générer un custom_id unique au format 3 lettres + 4 chiffres
CREATE OR REPLACE FUNCTION generate_transaction_custom_id()
RETURNS TEXT AS $$
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
  WHILE EXISTS (SELECT 1 FROM transactions WHERE custom_id = new_custom_id) LOOP
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
$$ LANGUAGE plpgsql;

-- Créer une nouvelle table transactions complète selon les spécifications
DROP TABLE IF EXISTS enhanced_transactions;
CREATE TABLE enhanced_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  custom_id VARCHAR(7) UNIQUE NOT NULL DEFAULT generate_transaction_custom_id(),
  sender_id UUID NOT NULL,
  receiver_id UUID NOT NULL,
  amount NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  currency VARCHAR(3) NOT NULL DEFAULT 'GNF',
  method VARCHAR(30) NOT NULL DEFAULT 'wallet', -- wallet, card, mobile_money, escrow
  status VARCHAR(20) NOT NULL DEFAULT 'pending', -- pending, completed, failed, refunded
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  
  -- Contraintes
  CONSTRAINT different_users CHECK (sender_id != receiver_id),
  CONSTRAINT valid_currency CHECK (currency IN ('GNF', 'USD', 'EUR', 'XOF')),
  CONSTRAINT valid_method CHECK (method IN ('wallet', 'card', 'mobile_money', 'escrow')),
  CONSTRAINT valid_status CHECK (status IN ('pending', 'completed', 'failed', 'refunded', 'cancelled'))
);

-- Activer RLS
ALTER TABLE enhanced_transactions ENABLE ROW LEVEL SECURITY;

-- Politiques RLS
CREATE POLICY "Users can view their transactions" ON enhanced_transactions
  FOR SELECT USING (
    auth.uid() = sender_id OR auth.uid() = receiver_id
  );

CREATE POLICY "Users can create transactions as sender" ON enhanced_transactions
  FOR INSERT WITH CHECK (
    auth.uid() = sender_id
  );

CREATE POLICY "Users can update their transactions" ON enhanced_transactions
  FOR UPDATE USING (
    auth.uid() = sender_id OR auth.uid() = receiver_id
  );

-- Trigger pour mettre à jour updated_at
CREATE TRIGGER update_enhanced_transactions_updated_at
  BEFORE UPDATE ON enhanced_transactions
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- Fonction pour traiter une transaction wallet
CREATE OR REPLACE FUNCTION process_wallet_transaction(
  p_sender_id UUID,
  p_receiver_id UUID,
  p_amount NUMERIC,
  p_currency VARCHAR DEFAULT 'GNF',
  p_description TEXT DEFAULT NULL
)
RETURNS UUID AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER;