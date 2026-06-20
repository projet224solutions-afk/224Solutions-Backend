-- Créer la table system_settings pour les paramètres système
CREATE TABLE IF NOT EXISTS system_settings (
  id SERIAL PRIMARY KEY,
  setting_key VARCHAR(50) UNIQUE NOT NULL,
  setting_value VARCHAR(50) NOT NULL,
  description TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Valeur par défaut du taux de commission
INSERT INTO system_settings (setting_key, setting_value, description)
VALUES ('transfer_fee_percent', '1.5', 'Taux de commission pour les transferts entre wallets (en %)')
ON CONFLICT (setting_key) DO NOTHING;

-- Enable RLS
ALTER TABLE system_settings ENABLE ROW LEVEL SECURITY;

-- Policy: Tout le monde peut lire
CREATE POLICY "Anyone can view system settings"
ON system_settings FOR SELECT
USING (true);

-- Policy: Seul le PDG peut modifier
CREATE POLICY "Only PDG can update system settings"
ON system_settings FOR UPDATE
USING (
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE profiles.id = auth.uid() 
    AND profiles.role = 'admin'
  )
);

-- Fonction pour obtenir le taux de commission
CREATE OR REPLACE FUNCTION get_transfer_fee_percent()
RETURNS NUMERIC AS $$
DECLARE
  fee_percent NUMERIC;
BEGIN
  SELECT setting_value::NUMERIC INTO fee_percent
  FROM system_settings
  WHERE setting_key = 'transfer_fee_percent';
  
  RETURN COALESCE(fee_percent, 1.5);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction de prévisualisation du transfert
CREATE OR REPLACE FUNCTION preview_wallet_transfer(
  p_sender_id UUID,
  p_receiver_id UUID,
  p_amount NUMERIC,
  p_currency VARCHAR DEFAULT 'GNF'
)
RETURNS JSON AS $$
DECLARE
  fee_percent NUMERIC;
  fee_amount NUMERIC;
  total_debit NUMERIC;
  sender_balance NUMERIC;
  sender_status VARCHAR;
  receiver_exists BOOLEAN;
BEGIN
  -- Obtenir le taux de commission
  fee_percent := get_transfer_fee_percent();
  
  -- Calculer les frais
  fee_amount := ROUND((p_amount * fee_percent) / 100, 0);
  total_debit := p_amount + fee_amount;
  
  -- Vérifier l'expéditeur
  SELECT balance, status INTO sender_balance, sender_status
  FROM wallets
  WHERE user_id = p_sender_id AND currency = p_currency;
  
  IF sender_balance IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Wallet expéditeur introuvable'
    );
  END IF;
  
  IF sender_status != 'active' THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Wallet expéditeur inactif'
    );
  END IF;
  
  -- Vérifier le destinataire
  SELECT EXISTS(
    SELECT 1 FROM wallets 
    WHERE user_id = p_receiver_id AND status = 'active'
  ) INTO receiver_exists;
  
  IF NOT receiver_exists THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Destinataire introuvable ou inactif'
    );
  END IF;
  
  -- Vérifier que l'expéditeur n'est pas le destinataire
  IF p_sender_id = p_receiver_id THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Impossible de transférer vers votre propre compte'
    );
  END IF;
  
  -- Vérifier le solde
  IF sender_balance < total_debit THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Solde insuffisant',
      'current_balance', sender_balance,
      'required', total_debit,
      'shortage', total_debit - sender_balance
    );
  END IF;
  
  -- Retourner la prévisualisation
  RETURN json_build_object(
    'success', true,
    'amount', p_amount,
    'fee_percent', fee_percent,
    'fee_amount', fee_amount,
    'total_debit', total_debit,
    'amount_received', p_amount,
    'current_balance', sender_balance,
    'balance_after', sender_balance - total_debit
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Mise à jour de la fonction process_wallet_transaction pour inclure les frais
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
    fee_percent NUMERIC;
    fee_amount NUMERIC;
    total_debit NUMERIC;
    pdg_wallet_id UUID;
BEGIN
    -- Obtenir le taux de commission
    fee_percent := get_transfer_fee_percent();
    fee_amount := ROUND((p_amount * fee_percent) / 100, 0);
    total_debit := p_amount + fee_amount;
    
    -- Vérifier que l'expéditeur n'est pas le destinataire
    IF p_sender_id = p_receiver_id THEN
        RAISE EXCEPTION 'Impossible de transférer vers votre propre compte';
    END IF;
    
    -- Vérifier le solde de l'expéditeur
    SELECT balance INTO sender_wallet_balance 
    FROM wallets 
    WHERE user_id = p_sender_id AND currency = p_currency AND status = 'active';
    
    IF sender_wallet_balance IS NULL THEN
        RAISE EXCEPTION 'Wallet non trouvé pour l''expéditeur';
    END IF;
    
    IF sender_wallet_balance < total_debit THEN
        RAISE EXCEPTION 'Solde insuffisant. Requis: % GNF (dont % GNF de frais)', total_debit, fee_amount;
    END IF;
    
    -- Créer la transaction
    INSERT INTO enhanced_transactions (sender_id, receiver_id, amount, currency, method, metadata, status)
    VALUES (p_sender_id, p_receiver_id, p_amount, p_currency, 'wallet', 
            jsonb_build_object(
              'description', COALESCE(p_description, ''),
              'fee_percent', fee_percent,
              'fee_amount', fee_amount,
              'total_debited', total_debit
            ), 'pending')
    RETURNING id INTO transaction_id;
    
    -- Débiter l'expéditeur (montant + frais)
    UPDATE wallets 
    SET balance = balance - total_debit, updated_at = now()
    WHERE user_id = p_sender_id AND currency = p_currency;
    
    -- Créditer le destinataire (montant net)
    INSERT INTO wallets (user_id, balance, currency, status)
    VALUES (p_receiver_id, p_amount, p_currency, 'active')
    ON CONFLICT (user_id, currency) 
    DO UPDATE SET balance = wallets.balance + p_amount, updated_at = now();
    
    -- Créditer les frais au PDG
    SELECT id INTO pdg_wallet_id
    FROM profiles
    WHERE role = 'admin'
    LIMIT 1;
    
    IF pdg_wallet_id IS NOT NULL AND fee_amount > 0 THEN
      INSERT INTO wallets (user_id, balance, currency, status)
      VALUES (pdg_wallet_id, fee_amount, p_currency, 'active')
      ON CONFLICT (user_id, currency) 
      DO UPDATE SET balance = wallets.balance + fee_amount, updated_at = now();
    END IF;
    
    -- Marquer comme complétée
    UPDATE enhanced_transactions 
    SET status = 'completed', updated_at = now()
    WHERE id = transaction_id;
    
    RETURN transaction_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;