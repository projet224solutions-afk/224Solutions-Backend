CREATE OR REPLACE FUNCTION public.process_deposit_payment(p_transaction_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_transaction RECORD;
    v_wallet_id BIGINT;
    v_new_balance NUMERIC;
    v_tx_id TEXT;
BEGIN
    SELECT * INTO v_transaction
    FROM stripe_transactions
    WHERE id = p_transaction_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Transaction not found');
    END IF;

    IF (v_transaction.metadata->>'wallet_credited')::boolean IS TRUE THEN
        RETURN jsonb_build_object('success', true, 'already_credited', true, 'message', 'Wallet already credited');
    END IF;

    SELECT id INTO v_wallet_id
    FROM wallets
    WHERE user_id = v_transaction.buyer_id 
      AND UPPER(currency) = UPPER(v_transaction.currency);
    
    IF v_wallet_id IS NULL THEN
        INSERT INTO wallets (user_id, balance, currency, wallet_status)
        VALUES (v_transaction.buyer_id, 0, UPPER(v_transaction.currency), 'active')
        RETURNING id INTO v_wallet_id;
    END IF;

    UPDATE wallets
    SET balance = balance + v_transaction.seller_net_amount,
        updated_at = NOW()
    WHERE id = v_wallet_id
    RETURNING balance INTO v_new_balance;

    v_tx_id := 'DEP-' || gen_random_uuid()::TEXT;

    INSERT INTO wallet_transactions (
        transaction_id, receiver_wallet_id, receiver_user_id, amount, net_amount, currency,
        transaction_type, status, description, reference_id
    )
    VALUES (
        v_tx_id,
        v_wallet_id,
        v_transaction.buyer_id,
        v_transaction.seller_net_amount,
        v_transaction.seller_net_amount,
        UPPER(v_transaction.currency),
        'deposit'::transaction_type,
        'completed'::transaction_status,
        'Dépôt par carte bancaire',
        v_transaction.id::TEXT
    );

    UPDATE stripe_transactions
    SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
        'wallet_credited', true,
        'wallet_credited_at', NOW()::TEXT,
        'wallet_id', v_wallet_id
    ),
    updated_at = NOW()
    WHERE id = p_transaction_id;

    RETURN jsonb_build_object(
        'success', true,
        'wallet_id', v_wallet_id,
        'new_balance', v_new_balance,
        'amount_credited', v_transaction.seller_net_amount,
        'currency', v_transaction.currency
    );
END;
$$;