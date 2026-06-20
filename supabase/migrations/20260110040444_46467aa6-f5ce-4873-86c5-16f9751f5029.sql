
-- 1. Supprimer les deux versions conflictuelles de la fonction
DROP FUNCTION IF EXISTS process_wallet_transaction(text, text, numeric, text, text);
DROP FUNCTION IF EXISTS process_wallet_transaction(uuid, uuid, numeric, character varying, text);

-- 2. Créer la table enhanced_transactions
CREATE TABLE IF NOT EXISTS public.enhanced_transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id UUID NOT NULL,
    receiver_id UUID NOT NULL,
    amount NUMERIC NOT NULL,
    currency VARCHAR(10) DEFAULT 'GNF',
    method VARCHAR(50) DEFAULT 'wallet',
    status VARCHAR(20) DEFAULT 'pending',
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Index pour performance
CREATE INDEX IF NOT EXISTS idx_enhanced_transactions_sender ON enhanced_transactions(sender_id);
CREATE INDEX IF NOT EXISTS idx_enhanced_transactions_receiver ON enhanced_transactions(receiver_id);
CREATE INDEX IF NOT EXISTS idx_enhanced_transactions_status ON enhanced_transactions(status);
CREATE INDEX IF NOT EXISTS idx_enhanced_transactions_created ON enhanced_transactions(created_at DESC);

-- RLS
ALTER TABLE enhanced_transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own transactions"
ON enhanced_transactions FOR SELECT
USING (auth.uid() = sender_id OR auth.uid() = receiver_id);

CREATE POLICY "Users can create transactions as sender"
ON enhanced_transactions FOR INSERT
WITH CHECK (auth.uid() = sender_id);

-- 3. Créer la fonction unifiée
CREATE OR REPLACE FUNCTION process_wallet_transaction(
    p_sender_id UUID,
    p_receiver_id UUID,
    p_amount NUMERIC,
    p_currency VARCHAR DEFAULT 'GNF',
    p_description TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_transaction_id UUID;
    v_sender_balance NUMERIC;
    v_fee_percent NUMERIC := 1.5;
    v_fee_amount NUMERIC;
    v_total_debit NUMERIC;
    v_sender_name TEXT;
    v_receiver_name TEXT;
BEGIN
    -- Récupérer les noms
    SELECT full_name INTO v_sender_name FROM profiles WHERE id = p_sender_id;
    SELECT full_name INTO v_receiver_name FROM profiles WHERE id = p_receiver_id;
    
    -- Vérifier le solde
    SELECT balance INTO v_sender_balance FROM wallets WHERE user_id = p_sender_id AND currency = p_currency;
    
    IF v_sender_balance IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Wallet expéditeur non trouvé');
    END IF;
    
    -- Calculer les frais
    v_fee_amount := ROUND((p_amount * v_fee_percent / 100), 2);
    v_total_debit := p_amount + v_fee_amount;
    
    IF v_sender_balance < v_total_debit THEN
        RETURN jsonb_build_object(
            'success', false, 
            'error', format('Solde insuffisant. Disponible: %s GNF, Requis: %s GNF', v_sender_balance, v_total_debit)
        );
    END IF;
    
    -- Créer la transaction
    INSERT INTO enhanced_transactions (sender_id, receiver_id, amount, currency, method, status, metadata)
    VALUES (
        p_sender_id, p_receiver_id, p_amount, p_currency, 'wallet', 'completed',
        jsonb_build_object(
            'description', COALESCE(p_description, ''),
            'fee_percent', v_fee_percent,
            'fee_amount', v_fee_amount,
            'total_debit', v_total_debit,
            'sender_name', v_sender_name,
            'receiver_name', v_receiver_name
        )
    )
    RETURNING id INTO v_transaction_id;
    
    -- Débiter l'expéditeur
    UPDATE wallets SET balance = balance - v_total_debit, updated_at = now()
    WHERE user_id = p_sender_id AND currency = p_currency;
    
    -- Créditer le destinataire
    INSERT INTO wallets (user_id, balance, currency)
    VALUES (p_receiver_id, p_amount, p_currency)
    ON CONFLICT (user_id, currency) 
    DO UPDATE SET balance = wallets.balance + p_amount, updated_at = now();
    
    RETURN jsonb_build_object(
        'success', true,
        'transaction_id', v_transaction_id,
        'amount', p_amount,
        'fee', v_fee_amount,
        'total_debit', v_total_debit,
        'new_balance', v_sender_balance - v_total_debit
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
