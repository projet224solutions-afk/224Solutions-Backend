-- Table pour les transactions financières cross-platform
CREATE TABLE IF NOT EXISTS financial_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  transaction_type TEXT NOT NULL CHECK (transaction_type IN ('card_to_om', 'wallet_to_card', 'card_to_wallet')),
  amount NUMERIC NOT NULL CHECK (amount > 0),
  currency TEXT DEFAULT 'GNF',
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'failed', 'cancelled')),
  source_reference TEXT,
  destination_reference TEXT,
  api_response JSONB,
  error_message TEXT,
  fees NUMERIC DEFAULT 0,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ,
  created_by UUID REFERENCES auth.users(id)
);

-- Index pour les requêtes fréquentes
CREATE INDEX idx_financial_transactions_user ON financial_transactions(user_id);
CREATE INDEX idx_financial_transactions_type ON financial_transactions(transaction_type);
CREATE INDEX idx_financial_transactions_status ON financial_transactions(status);
CREATE INDEX idx_financial_transactions_created ON financial_transactions(created_at DESC);

-- RLS policies
ALTER TABLE financial_transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own transactions"
  ON financial_transactions FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own transactions"
  ON financial_transactions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Fonction pour calculer les frais
CREATE OR REPLACE FUNCTION calculate_transaction_fees(
  p_amount NUMERIC,
  p_transaction_type TEXT
)
RETURNS NUMERIC AS $$
BEGIN
  CASE p_transaction_type
    WHEN 'card_to_om' THEN
      RETURN p_amount * 0.02;
    WHEN 'wallet_to_card' THEN
      RETURN p_amount * 0.01;
    WHEN 'card_to_wallet' THEN
      RETURN p_amount * 0.01;
    ELSE
      RETURN 0;
  END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Fonction pour traiter transaction carte vers Orange Money
CREATE OR REPLACE FUNCTION process_card_to_om(
  p_user_id UUID,
  p_card_id TEXT,
  p_phone_number TEXT,
  p_amount NUMERIC
)
RETURNS UUID AS $$
DECLARE
  v_transaction_id UUID;
  v_card_balance NUMERIC;
  v_fees NUMERIC;
BEGIN
  v_fees := calculate_transaction_fees(p_amount, 'card_to_om');
  
  SELECT balance INTO v_card_balance
  FROM virtual_cards
  WHERE id::TEXT = p_card_id AND user_id = p_user_id AND status = 'active';
  
  IF v_card_balance IS NULL THEN
    RAISE EXCEPTION 'Carte virtuelle non trouvée ou inactive';
  END IF;
  
  IF v_card_balance < (p_amount + v_fees) THEN
    RAISE EXCEPTION 'Solde insuffisant sur la carte virtuelle';
  END IF;
  
  INSERT INTO financial_transactions (
    user_id, transaction_type, amount, source_reference, 
    destination_reference, fees, status
  )
  VALUES (
    p_user_id, 'card_to_om', p_amount, p_card_id,
    p_phone_number, v_fees, 'pending'
  )
  RETURNING id INTO v_transaction_id;
  
  UPDATE virtual_cards
  SET balance = balance - (p_amount + v_fees),
      updated_at = now()
  WHERE id::TEXT = p_card_id AND user_id = p_user_id;
  
  RETURN v_transaction_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour traiter recharge carte depuis wallet
CREATE OR REPLACE FUNCTION process_wallet_to_card(
  p_user_id UUID,
  p_card_id TEXT,
  p_amount NUMERIC
)
RETURNS UUID AS $$
DECLARE
  v_transaction_id UUID;
  v_wallet_balance NUMERIC;
  v_fees NUMERIC;
BEGIN
  v_fees := calculate_transaction_fees(p_amount, 'wallet_to_card');
  
  SELECT balance INTO v_wallet_balance
  FROM wallets
  WHERE user_id = p_user_id AND status = 'active';
  
  IF v_wallet_balance IS NULL THEN
    RAISE EXCEPTION 'Wallet non trouvé';
  END IF;
  
  IF v_wallet_balance < (p_amount + v_fees) THEN
    RAISE EXCEPTION 'Solde wallet insuffisant';
  END IF;
  
  INSERT INTO financial_transactions (
    user_id, transaction_type, amount, source_reference,
    destination_reference, fees, status
  )
  VALUES (
    p_user_id, 'wallet_to_card', p_amount, 'wallet',
    p_card_id, v_fees, 'pending'
  )
  RETURNING id INTO v_transaction_id;
  
  UPDATE wallets
  SET balance = balance - (p_amount + v_fees),
      updated_at = now()
  WHERE user_id = p_user_id;
  
  UPDATE virtual_cards
  SET balance = balance + p_amount,
      updated_at = now()
  WHERE id::TEXT = p_card_id AND user_id = p_user_id;
  
  UPDATE financial_transactions
  SET status = 'completed', completed_at = now()
  WHERE id = v_transaction_id;
  
  RETURN v_transaction_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour traiter recharge wallet depuis carte
CREATE OR REPLACE FUNCTION process_card_to_wallet(
  p_user_id UUID,
  p_card_id TEXT,
  p_amount NUMERIC
)
RETURNS UUID AS $$
DECLARE
  v_transaction_id UUID;
  v_card_balance NUMERIC;
  v_fees NUMERIC;
BEGIN
  v_fees := calculate_transaction_fees(p_amount, 'card_to_wallet');
  
  SELECT balance INTO v_card_balance
  FROM virtual_cards
  WHERE id::TEXT = p_card_id AND user_id = p_user_id AND status = 'active';
  
  IF v_card_balance IS NULL THEN
    RAISE EXCEPTION 'Carte virtuelle non trouvée';
  END IF;
  
  IF v_card_balance < (p_amount + v_fees) THEN
    RAISE EXCEPTION 'Solde carte insuffisant';
  END IF;
  
  INSERT INTO financial_transactions (
    user_id, transaction_type, amount, source_reference,
    destination_reference, fees, status
  )
  VALUES (
    p_user_id, 'card_to_wallet', p_amount, p_card_id,
    'wallet', v_fees, 'pending'
  )
  RETURNING id INTO v_transaction_id;
  
  UPDATE virtual_cards
  SET balance = balance - (p_amount + v_fees),
      updated_at = now()
  WHERE id::TEXT = p_card_id AND user_id = p_user_id;
  
  UPDATE wallets
  SET balance = balance + p_amount,
      updated_at = now()
  WHERE user_id = p_user_id;
  
  UPDATE financial_transactions
  SET status = 'completed', completed_at = now()
  WHERE id = v_transaction_id;
  
  RETURN v_transaction_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;