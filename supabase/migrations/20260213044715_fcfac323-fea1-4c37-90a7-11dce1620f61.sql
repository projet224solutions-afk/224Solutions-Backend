CREATE OR REPLACE FUNCTION public.process_wallet_transaction(
    p_sender_id uuid, 
    p_receiver_id uuid, 
    p_amount numeric, 
    p_currency character varying DEFAULT 'GNF'::character varying, 
    p_description text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
    SELECT balance INTO v_sender_balance FROM wallets WHERE user_id = p_sender_id;
    
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
    WHERE user_id = p_sender_id;
    
    -- Créditer le destinataire (upsert avec la bonne contrainte user_id)
    INSERT INTO wallets (user_id, balance, currency)
    VALUES (p_receiver_id, p_amount, p_currency)
    ON CONFLICT (user_id) 
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
$function$;