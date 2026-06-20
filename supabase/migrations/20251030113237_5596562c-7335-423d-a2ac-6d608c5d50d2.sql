-- Corriger la fonction process_wallet_transaction pour inclure les frais de transfert
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
    v_fee_percent NUMERIC;
    v_fee_amount NUMERIC;
    v_total_debit NUMERIC;
BEGIN
    -- Vérifier le solde de l'expéditeur
    SELECT balance INTO sender_wallet_balance 
    FROM wallets 
    WHERE user_id = p_sender_id AND currency = p_currency;
    
    IF sender_wallet_balance IS NULL THEN
        RAISE EXCEPTION 'Wallet non trouvé pour l''expéditeur';
    END IF;
    
    -- Récupérer le taux de frais depuis system_settings
    SELECT COALESCE(
        (SELECT setting_value::NUMERIC FROM system_settings WHERE setting_key = 'transfer_fee_percent'),
        1.0
    ) INTO v_fee_percent;
    
    -- Calculer les frais et le total à débiter
    v_fee_amount := ROUND((p_amount * v_fee_percent / 100), 2);
    v_total_debit := p_amount + v_fee_amount;
    
    -- Vérifier le solde suffisant (montant + frais)
    IF sender_wallet_balance < v_total_debit THEN
        RAISE EXCEPTION 'Solde insuffisant. Solde: % GNF, Requis: % GNF (dont % GNF de frais)', 
            sender_wallet_balance, v_total_debit, v_fee_amount;
    END IF;
    
    -- Créer la transaction avec les métadonnées des frais
    INSERT INTO enhanced_transactions (sender_id, receiver_id, amount, currency, method, metadata, status)
    VALUES (p_sender_id, p_receiver_id, p_amount, p_currency, 'wallet', 
            jsonb_build_object(
                'description', COALESCE(p_description, ''),
                'fee_percent', v_fee_percent,
                'fee_amount', v_fee_amount,
                'total_debit', v_total_debit,
                'amount_received', p_amount
            ), 'pending')
    RETURNING id INTO transaction_id;
    
    -- Débiter l'expéditeur (montant + frais)
    UPDATE wallets 
    SET balance = balance - v_total_debit, updated_at = now()
    WHERE user_id = p_sender_id AND currency = p_currency;
    
    -- Créditer le destinataire (montant sans les frais)
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;