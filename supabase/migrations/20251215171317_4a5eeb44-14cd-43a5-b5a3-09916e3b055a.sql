
-- CORRECTION: Recréer subscribe_driver avec gestion billing_cycle et wallet_transactions

CREATE OR REPLACE FUNCTION public.subscribe_driver(
  p_user_id UUID,
  p_type TEXT,
  p_payment_method TEXT,
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
  v_wallet_id UUID;
  v_wallet_balance NUMERIC;
  v_transaction_uuid UUID;
  v_transaction_code TEXT;
  v_yearly_price NUMERIC;
BEGIN
  -- Récupérer la config
  SELECT price, duration_days, yearly_price 
  INTO v_price, v_duration_days, v_yearly_price
  FROM driver_subscription_config
  WHERE subscription_type = 'both' AND is_active = TRUE
  LIMIT 1;
  
  IF v_price IS NULL THEN
    RAISE EXCEPTION 'Configuration d''abonnement non trouvée';
  END IF;
  
  -- Calculer le prix et la durée selon le cycle
  IF p_billing_cycle = 'yearly' THEN
    v_price := COALESCE(v_yearly_price, v_price * 12);
    v_duration_days := 365;
  END IF;
  
  -- Récupérer et vérifier le wallet
  SELECT id, balance INTO v_wallet_id, v_wallet_balance
  FROM wallets
  WHERE user_id = p_user_id
  FOR UPDATE;
  
  IF v_wallet_id IS NULL THEN
    RAISE EXCEPTION 'Wallet non trouvé pour cet utilisateur';
  END IF;
  
  IF v_wallet_balance < v_price THEN
    RAISE EXCEPTION 'Solde insuffisant. Solde: % GNF, Requis: % GNF', v_wallet_balance, v_price;
  END IF;
  
  -- Débiter le wallet
  UPDATE wallets
  SET balance = balance - v_price, updated_at = NOW()
  WHERE id = v_wallet_id;
  
  -- Générer l'ID de transaction
  v_transaction_uuid := gen_random_uuid();
  v_transaction_code := COALESCE(p_transaction_id, 'DRV-SUB-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || SUBSTRING(v_transaction_uuid::text, 1, 8));
  
  -- Enregistrer la transaction wallet
  INSERT INTO wallet_transactions (
    id, transaction_id, sender_wallet_id, receiver_wallet_id,
    amount, fee, net_amount, currency,
    transaction_type, status, description, metadata,
    created_at, completed_at
  ) VALUES (
    v_transaction_uuid, v_transaction_code, v_wallet_id, NULL,
    v_price, 0, v_price, 'GNF',
    'subscription', 'completed',
    'Abonnement ' || p_type || ' - ' || p_billing_cycle,
    jsonb_build_object('type', p_type, 'billing_cycle', p_billing_cycle, 'duration_days', v_duration_days),
    NOW(), NOW()
  );
  
  -- Calculer la date de fin
  v_end_date := NOW() + (v_duration_days || ' days')::INTERVAL;
  
  -- Désactiver les anciens abonnements
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
    jsonb_build_object('wallet_transaction_id', v_transaction_uuid)
  ) RETURNING id INTO v_subscription_id;
  
  -- Enregistrer le revenu abonnement
  INSERT INTO driver_subscription_revenues (
    subscription_id, user_id, amount, payment_method, transaction_id
  ) VALUES (
    v_subscription_id, p_user_id, v_price, p_payment_method, v_transaction_code
  );
  
  -- Enregistrer revenu PDG
  INSERT INTO revenus_pdg (
    id, source_type, transaction_id, user_id, amount, percentage_applied, metadata, created_at
  ) VALUES (
    gen_random_uuid(), 'abonnement_driver', v_transaction_uuid, p_user_id, v_price, 100,
    jsonb_build_object('subscription_id', v_subscription_id, 'type', p_type, 'billing_cycle', p_billing_cycle),
    NOW()
  );
  
  RETURN v_subscription_id;
END;
$$;
