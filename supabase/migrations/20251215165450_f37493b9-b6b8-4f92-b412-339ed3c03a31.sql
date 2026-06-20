
-- Recréer la fonction record_subscription_payment avec débit wallet
CREATE OR REPLACE FUNCTION public.record_subscription_payment(
  p_user_id UUID,
  p_plan_id UUID,
  p_price_paid NUMERIC,
  p_payment_method TEXT DEFAULT 'wallet',
  p_payment_transaction_id TEXT DEFAULT NULL,
  p_billing_cycle TEXT DEFAULT 'monthly'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subscription_id UUID;
  v_period_end TIMESTAMP WITH TIME ZONE;
  v_wallet_balance NUMERIC;
  v_transaction_id UUID;
BEGIN
  -- Vérifier que le montant est positif pour les plans payants
  IF p_price_paid > 0 THEN
    -- Récupérer le solde du wallet
    SELECT balance INTO v_wallet_balance
    FROM wallets
    WHERE user_id = p_user_id;
    
    -- Vérifier que le wallet existe
    IF v_wallet_balance IS NULL THEN
      RAISE EXCEPTION 'Wallet non trouvé pour cet utilisateur';
    END IF;
    
    -- Vérifier le solde suffisant
    IF v_wallet_balance < p_price_paid THEN
      RAISE EXCEPTION 'Solde insuffisant. Solde: % GNF, Requis: % GNF', v_wallet_balance, p_price_paid;
    END IF;
    
    -- Débiter le wallet
    UPDATE wallets
    SET balance = balance - p_price_paid,
        updated_at = NOW()
    WHERE user_id = p_user_id;
    
    -- Enregistrer la transaction wallet
    INSERT INTO wallet_transactions (
      id,
      wallet_id,
      type,
      amount,
      description,
      status,
      created_at
    )
    SELECT 
      gen_random_uuid(),
      w.id,
      'subscription',
      -p_price_paid,
      'Paiement abonnement ' || p_billing_cycle || ' - Plan ID: ' || p_plan_id::text,
      'completed',
      NOW()
    FROM wallets w
    WHERE w.user_id = p_user_id
    RETURNING id INTO v_transaction_id;
  END IF;

  -- Annuler tous les abonnements actifs existants
  UPDATE subscriptions 
  SET status = 'cancelled', updated_at = NOW()
  WHERE user_id = p_user_id AND status = 'active';

  -- Calculer la date de fin selon le cycle
  CASE p_billing_cycle
    WHEN 'yearly' THEN
      v_period_end := NOW() + INTERVAL '1 year';
    WHEN 'quarterly' THEN
      v_period_end := NOW() + INTERVAL '3 months';
    ELSE
      v_period_end := NOW() + INTERVAL '1 month';
  END CASE;

  -- Créer le nouvel abonnement
  INSERT INTO subscriptions (
    user_id,
    plan_id,
    status,
    price_paid_gnf,
    billing_cycle,
    payment_method,
    payment_transaction_id,
    current_period_start,
    current_period_end,
    auto_renew,
    metadata,
    created_at,
    updated_at
  ) VALUES (
    p_user_id,
    p_plan_id,
    'active',
    p_price_paid::INTEGER,
    p_billing_cycle,
    p_payment_method,
    COALESCE(p_payment_transaction_id, v_transaction_id::text),
    NOW(),
    v_period_end,
    true,
    jsonb_build_object('wallet_transaction_id', v_transaction_id),
    NOW(),
    NOW()
  )
  RETURNING id INTO v_subscription_id;

  -- Enregistrer le revenu pour le PDG
  INSERT INTO revenus_pdg (
    source_type,
    source_id,
    amount,
    description,
    created_at
  ) VALUES (
    'subscription',
    v_subscription_id,
    p_price_paid,
    'Abonnement ' || p_billing_cycle || ' - Plan ID: ' || p_plan_id::text,
    NOW()
  );

  RETURN v_subscription_id;
END;
$$;
