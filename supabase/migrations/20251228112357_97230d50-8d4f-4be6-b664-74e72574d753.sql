-- Corriger la fonction subscribe_driver pour débiter le wallet
CREATE OR REPLACE FUNCTION subscribe_driver(
  p_user_id UUID,
  p_type TEXT,
  p_payment_method TEXT DEFAULT 'wallet',
  p_transaction_id TEXT DEFAULT NULL,
  p_billing_cycle TEXT DEFAULT 'monthly'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_price NUMERIC;
  v_duration_days INTEGER;
  v_subscription_id UUID;
  v_end_date TIMESTAMPTZ;
  v_wallet_balance NUMERIC;
  v_transaction_code TEXT;
  v_transaction_id UUID;
BEGIN
  -- Récupérer le prix et la durée selon le billing_cycle
  IF p_billing_cycle = 'yearly' THEN
    SELECT yearly_price, 365 INTO v_price, v_duration_days
    FROM driver_subscription_config
    WHERE subscription_type = 'both' AND is_active = TRUE
    LIMIT 1;
  ELSE
    SELECT price, duration_days INTO v_price, v_duration_days
    FROM driver_subscription_config
    WHERE subscription_type = 'both' AND is_active = TRUE
    LIMIT 1;
  END IF;
  
  IF v_price IS NULL THEN
    RAISE EXCEPTION 'Configuration d''abonnement non trouvée';
  END IF;
  
  -- Si paiement par wallet, vérifier et débiter le solde
  IF p_payment_method = 'wallet' THEN
    -- Vérifier le solde du wallet
    SELECT balance INTO v_wallet_balance
    FROM wallets
    WHERE user_id = p_user_id
    FOR UPDATE; -- Lock pour éviter les race conditions
    
    IF v_wallet_balance IS NULL THEN
      RAISE EXCEPTION 'Wallet non trouvé pour cet utilisateur';
    END IF;
    
    IF v_wallet_balance < v_price THEN
      RAISE EXCEPTION 'Solde insuffisant. Solde: % GNF, Prix: % GNF', v_wallet_balance, v_price;
    END IF;
    
    -- Débiter le wallet
    UPDATE wallets
    SET balance = balance - v_price,
        updated_at = NOW()
    WHERE user_id = p_user_id;
    
    -- Générer un code de transaction unique
    v_transaction_code := 'SUB-' || EXTRACT(EPOCH FROM NOW())::BIGINT || '-' || SUBSTRING(p_user_id::TEXT, 1, 8);
    
    -- Créer une transaction dans la table transactions
    INSERT INTO transactions (
      user_id,
      type,
      amount,
      status,
      description,
      reference,
      created_at
    ) VALUES (
      p_user_id,
      'subscription',
      -v_price, -- Montant négatif car c'est un débit
      'completed',
      'Abonnement ' || UPPER(p_type) || ' - ' || INITCAP(p_billing_cycle),
      v_transaction_code,
      NOW()
    ) RETURNING id INTO v_transaction_id;
  ELSE
    v_transaction_code := COALESCE(p_transaction_id, 'SUB-' || EXTRACT(EPOCH FROM NOW())::BIGINT || '-' || SUBSTRING(p_user_id::TEXT, 1, 8));
  END IF;
  
  -- Calculer la date de fin
  v_end_date := NOW() + (v_duration_days || ' days')::INTERVAL;
  
  -- Désactiver les anciens abonnements actifs
  UPDATE driver_subscriptions
  SET status = 'expired', updated_at = NOW()
  WHERE user_id = p_user_id AND status = 'active';
  
  -- Créer le nouvel abonnement
  INSERT INTO driver_subscriptions (
    user_id, type, price, status, start_date, end_date, 
    payment_method, transaction_id, billing_cycle, metadata
  ) VALUES (
    p_user_id, p_type, v_price, 'active', NOW(), v_end_date, 
    p_payment_method, v_transaction_code, p_billing_cycle,
    jsonb_build_object(
      'wallet_transaction_id', v_transaction_id,
      'subscribed_at', NOW(),
      'original_balance', v_wallet_balance,
      'new_balance', v_wallet_balance - v_price
    )
  ) RETURNING id INTO v_subscription_id;
  
  -- Enregistrer le revenu
  INSERT INTO driver_subscription_revenues (
    subscription_id, user_id, amount, payment_method, transaction_id
  ) VALUES (
    v_subscription_id, p_user_id, v_price, p_payment_method, v_transaction_code
  );
  
  RETURN v_subscription_id;
END;
$$;