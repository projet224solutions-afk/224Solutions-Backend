-- Fonction pour traiter un paiement réussi (appelée par le webhook Stripe)
-- Cette fonction crédite le wallet du vendeur avec le montant NET (après commission)
-- L'argent RÉEL reste sur Stripe jusqu'au payout

CREATE OR REPLACE FUNCTION process_successful_payment(p_transaction_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_transaction RECORD;
  v_seller_wallet RECORD;
  v_wallet_transaction_id UUID;
  v_result jsonb;
BEGIN
  -- 1. Récupérer la transaction
  SELECT * INTO v_transaction
  FROM stripe_transactions
  WHERE id = p_transaction_id;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Transaction not found'
    );
  END IF;
  
  -- Vérifier que la transaction n'a pas déjà été traitée
  IF v_transaction.status = 'SUCCEEDED' AND v_transaction.paid_at IS NOT NULL THEN
    -- Vérifier si le wallet a déjà été crédité
    IF EXISTS (
      SELECT 1 FROM wallet_transactions 
      WHERE reference_id = p_transaction_id::text 
      AND transaction_type = 'credit'
    ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Payment already processed'
      );
    END IF;
  END IF;
  
  -- 2. Récupérer ou créer le wallet du vendeur
  SELECT * INTO v_seller_wallet
  FROM wallets
  WHERE user_id = v_transaction.seller_id;
  
  IF NOT FOUND THEN
    -- Créer le wallet du vendeur s'il n'existe pas
    INSERT INTO wallets (
      user_id, 
      balance, 
      currency, 
      wallet_status,
      total_received,
      total_sent
    )
    VALUES (
      v_transaction.seller_id, 
      0, 
      v_transaction.currency,
      'active',
      0,
      0
    )
    RETURNING * INTO v_seller_wallet;
  END IF;
  
  -- 3. Créditer le wallet du vendeur avec le montant NET
  -- (Le montant brut moins la commission de la plateforme)
  UPDATE wallets
  SET 
    balance = balance + v_transaction.seller_net_amount,
    total_received = COALESCE(total_received, 0) + v_transaction.seller_net_amount,
    last_transaction_at = NOW(),
    updated_at = NOW()
  WHERE user_id = v_transaction.seller_id;
  
  -- 4. Enregistrer la transaction wallet
  INSERT INTO wallet_transactions (
    id,
    wallet_id,
    amount,
    transaction_type,
    description,
    reference_id,
    status,
    created_at
  )
  VALUES (
    gen_random_uuid(),
    v_seller_wallet.id,
    v_transaction.seller_net_amount,
    'credit',
    'Paiement carte - Commission ' || v_transaction.commission_rate || '% déduite',
    p_transaction_id::text,
    'completed',
    NOW()
  )
  RETURNING id INTO v_wallet_transaction_id;
  
  -- 5. Mettre à jour la commande liée si elle existe
  IF v_transaction.order_id IS NOT NULL THEN
    UPDATE orders
    SET 
      payment_status = 'paid',
      status = 'confirmed',
      updated_at = NOW()
    WHERE id = v_transaction.order_id::uuid;
  END IF;
  
  -- 6. Log pour audit
  INSERT INTO audit_logs (
    action,
    actor_id,
    target_type,
    target_id,
    data_json
  )
  VALUES (
    'stripe_payment_processed',
    v_transaction.seller_id,
    'stripe_transaction',
    p_transaction_id::text,
    jsonb_build_object(
      'amount', v_transaction.amount,
      'commission_amount', v_transaction.commission_amount,
      'seller_net_amount', v_transaction.seller_net_amount,
      'commission_rate', v_transaction.commission_rate,
      'wallet_transaction_id', v_wallet_transaction_id
    )
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'wallet_credited', v_transaction.seller_net_amount,
    'commission_retained', v_transaction.commission_amount,
    'wallet_transaction_id', v_wallet_transaction_id
  );

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;
$$;

-- Ajouter colonnes manquantes si elles n'existent pas
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name = 'stripe_transactions' AND column_name = 'stripe_charge_id') THEN
    ALTER TABLE stripe_transactions ADD COLUMN stripe_charge_id text;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name = 'stripe_transactions' AND column_name = 'last4') THEN
    ALTER TABLE stripe_transactions ADD COLUMN last4 varchar(4);
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name = 'stripe_transactions' AND column_name = 'card_brand') THEN
    ALTER TABLE stripe_transactions ADD COLUMN card_brand varchar(20);
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name = 'stripe_transactions' AND column_name = 'three_ds_status') THEN
    ALTER TABLE stripe_transactions ADD COLUMN three_ds_status varchar(50);
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name = 'stripe_transactions' AND column_name = 'requires_3ds') THEN
    ALTER TABLE stripe_transactions ADD COLUMN requires_3ds boolean DEFAULT false;
  END IF;
  
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name = 'stripe_transactions' AND column_name = 'error_code') THEN
    ALTER TABLE stripe_transactions ADD COLUMN error_code varchar(100);
  END IF;
END $$;

-- Commentaire pour documentation
COMMENT ON FUNCTION process_successful_payment IS 
'Traite un paiement Stripe réussi:
- Crédite le wallet INTERNE du vendeur (montant NET après commission)
- L''argent RÉEL reste sur le compte Stripe de 224Solutions
- La commission est retenue sur Stripe
- Le payout au vendeur se fait séparément (manuel ou automatique)';