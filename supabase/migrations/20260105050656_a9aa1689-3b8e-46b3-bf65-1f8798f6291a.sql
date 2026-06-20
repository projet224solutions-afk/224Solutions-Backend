-- ============================================
-- FONCTION: process_successful_payment
-- Crédite le wallet vendeur après paiement Stripe réussi
-- ============================================

CREATE OR REPLACE FUNCTION public.process_successful_payment(p_transaction_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_transaction RECORD;
    v_seller_wallet_id UUID;
    v_platform_wallet_id UUID;
    v_result JSONB;
BEGIN
    -- Récupérer la transaction
    SELECT * INTO v_transaction
    FROM stripe_transactions
    WHERE id = p_transaction_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Transaction not found');
    END IF;
    
    -- Vérifier que le paiement est réussi
    IF v_transaction.status != 'SUCCEEDED' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Transaction not succeeded');
    END IF;
    
    -- Récupérer ou créer le wallet vendeur
    SELECT id INTO v_seller_wallet_id
    FROM wallets
    WHERE user_id = v_transaction.seller_id AND currency = v_transaction.currency;
    
    IF v_seller_wallet_id IS NULL THEN
        INSERT INTO wallets (user_id, balance, currency, wallet_status)
        VALUES (v_transaction.seller_id, 0, v_transaction.currency, 'active')
        RETURNING id INTO v_seller_wallet_id;
    END IF;
    
    -- Créditer le wallet vendeur avec le montant NET
    UPDATE wallets
    SET balance = balance + v_transaction.seller_net_amount,
        total_received = COALESCE(total_received, 0) + v_transaction.seller_net_amount,
        last_transaction_at = NOW(),
        updated_at = NOW()
    WHERE id = v_seller_wallet_id;
    
    -- Enregistrer la transaction wallet pour le vendeur
    INSERT INTO wallet_transactions (
        wallet_id,
        amount,
        type,
        description,
        reference_id,
        reference_type,
        status,
        balance_after
    )
    SELECT 
        v_seller_wallet_id,
        v_transaction.seller_net_amount,
        'credit',
        'Paiement carte reçu - Commission déduite: ' || v_transaction.commission_amount || ' ' || v_transaction.currency,
        v_transaction.id::TEXT,
        'stripe_payment',
        'completed',
        w.balance
    FROM wallets w WHERE w.id = v_seller_wallet_id;
    
    -- Marquer la transaction comme traitée
    UPDATE stripe_transactions
    SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
        'wallet_credited', true,
        'wallet_credited_at', NOW()::TEXT,
        'wallet_id', v_seller_wallet_id::TEXT
    ),
    updated_at = NOW()
    WHERE id = p_transaction_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'seller_wallet_id', v_seller_wallet_id,
        'amount_credited', v_transaction.seller_net_amount,
        'commission_retained', v_transaction.commission_amount
    );
    
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- ============================================
-- FONCTION: process_deposit_payment
-- Crédite le wallet après un dépôt par carte
-- ============================================

CREATE OR REPLACE FUNCTION public.process_deposit_payment(p_transaction_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_transaction RECORD;
    v_wallet_id UUID;
BEGIN
    -- Récupérer la transaction
    SELECT * INTO v_transaction
    FROM stripe_transactions
    WHERE id = p_transaction_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Transaction not found');
    END IF;
    
    -- Vérifier que c'est un dépôt
    IF v_transaction.metadata->>'type' != 'deposit' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Not a deposit transaction');
    END IF;
    
    -- Récupérer ou créer le wallet
    SELECT id INTO v_wallet_id
    FROM wallets
    WHERE user_id = v_transaction.buyer_id AND currency = v_transaction.currency;
    
    IF v_wallet_id IS NULL THEN
        INSERT INTO wallets (user_id, balance, currency, wallet_status)
        VALUES (v_transaction.buyer_id, 0, v_transaction.currency, 'active')
        RETURNING id INTO v_wallet_id;
    END IF;
    
    -- Créditer le wallet (montant net après frais Stripe)
    UPDATE wallets
    SET balance = balance + v_transaction.seller_net_amount,
        total_received = COALESCE(total_received, 0) + v_transaction.seller_net_amount,
        last_transaction_at = NOW(),
        updated_at = NOW()
    WHERE id = v_wallet_id;
    
    -- Enregistrer la transaction wallet
    INSERT INTO wallet_transactions (
        wallet_id,
        amount,
        type,
        description,
        reference_id,
        reference_type,
        status,
        balance_after
    )
    SELECT 
        v_wallet_id,
        v_transaction.seller_net_amount,
        'credit',
        'Dépôt par carte bancaire',
        v_transaction.id::TEXT,
        'stripe_deposit',
        'completed',
        w.balance
    FROM wallets w WHERE w.id = v_wallet_id;
    
    -- Marquer comme traité
    UPDATE stripe_transactions
    SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
        'wallet_credited', true,
        'wallet_credited_at', NOW()::TEXT
    ),
    updated_at = NOW()
    WHERE id = p_transaction_id;
    
    RETURN jsonb_build_object('success', true, 'wallet_id', v_wallet_id, 'amount_credited', v_transaction.seller_net_amount);
    
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- ============================================
-- FONCTION: process_taxi_payment
-- Crédite le wallet chauffeur après paiement course
-- ============================================

CREATE OR REPLACE FUNCTION public.process_taxi_card_payment(p_stripe_payment_intent_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_taxi_tx RECORD;
    v_driver_wallet_id UUID;
    v_driver_user_id UUID;
BEGIN
    -- Récupérer la transaction taxi
    SELECT * INTO v_taxi_tx
    FROM taxi_transactions
    WHERE provider_tx_id = p_stripe_payment_intent_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Taxi transaction not found');
    END IF;
    
    -- Récupérer l'user_id du chauffeur
    SELECT user_id INTO v_driver_user_id
    FROM taxi_drivers
    WHERE id = v_taxi_tx.driver_id;
    
    IF v_driver_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Driver not found');
    END IF;
    
    -- Récupérer ou créer le wallet chauffeur
    SELECT id INTO v_driver_wallet_id
    FROM wallets
    WHERE user_id = v_driver_user_id AND currency = 'GNF';
    
    IF v_driver_wallet_id IS NULL THEN
        INSERT INTO wallets (user_id, balance, currency, wallet_status)
        VALUES (v_driver_user_id, 0, 'GNF', 'active')
        RETURNING id INTO v_driver_wallet_id;
    END IF;
    
    -- Créditer le wallet chauffeur avec sa part
    UPDATE wallets
    SET balance = balance + v_taxi_tx.driver_share,
        total_received = COALESCE(total_received, 0) + v_taxi_tx.driver_share,
        last_transaction_at = NOW(),
        updated_at = NOW()
    WHERE id = v_driver_wallet_id;
    
    -- Enregistrer la transaction wallet
    INSERT INTO wallet_transactions (
        wallet_id,
        amount,
        type,
        description,
        reference_id,
        reference_type,
        status,
        balance_after
    )
    SELECT 
        v_driver_wallet_id,
        v_taxi_tx.driver_share,
        'credit',
        'Revenu course taxi #' || v_taxi_tx.ride_id,
        v_taxi_tx.id::TEXT,
        'taxi_ride',
        'completed',
        w.balance
    FROM wallets w WHERE w.id = v_driver_wallet_id;
    
    -- Marquer la transaction comme complète
    UPDATE taxi_transactions
    SET status = 'completed',
        completed_at = NOW(),
        metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(
            'wallet_credited', true,
            'wallet_id', v_driver_wallet_id::TEXT
        )
    WHERE id = v_taxi_tx.id;
    
    -- Mettre à jour le statut de paiement de la course
    UPDATE taxi_trips
    SET payment_status = 'paid'
    WHERE id = v_taxi_tx.ride_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'driver_wallet_id', v_driver_wallet_id,
        'driver_share', v_taxi_tx.driver_share,
        'platform_fee', v_taxi_tx.platform_fee
    );
    
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;