
-- CORRECTION: Recréer la fonction record_subscription_payment avec la bonne structure de tables

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
  v_wallet_id UUID;
  v_wallet_balance NUMERIC;
  v_transaction_id UUID;
  v_transaction_code TEXT;
BEGIN
  -- Vérifier que le montant est positif pour les plans payants
  IF p_price_paid > 0 THEN
    -- Récupérer le wallet et son solde
    SELECT id, balance INTO v_wallet_id, v_wallet_balance
    FROM wallets
    WHERE user_id = p_user_id
    FOR UPDATE; -- Lock pour éviter race condition
    
    -- Vérifier que le wallet existe
    IF v_wallet_id IS NULL THEN
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
    WHERE id = v_wallet_id;
    
    -- Générer un code de transaction unique
    v_transaction_id := gen_random_uuid();
    v_transaction_code := 'SUB-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || SUBSTRING(v_transaction_id::text, 1, 8);
    
    -- Enregistrer la transaction wallet avec la bonne structure
    INSERT INTO wallet_transactions (
      id,
      transaction_id,
      sender_wallet_id,
      receiver_wallet_id,
      amount,
      fee,
      net_amount,
      currency,
      transaction_type,
      status,
      description,
      metadata,
      created_at,
      completed_at
    ) VALUES (
      v_transaction_id,
      v_transaction_code,
      v_wallet_id,  -- sender = user wallet
      NULL,         -- receiver = null (paiement sortant)
      p_price_paid,
      0,            -- pas de frais sur abonnement
      p_price_paid,
      'GNF',
      'subscription',
      'completed',
      'Paiement abonnement ' || p_billing_cycle || ' - Plan ID: ' || p_plan_id::text,
      jsonb_build_object('plan_id', p_plan_id, 'billing_cycle', p_billing_cycle),
      NOW(),
      NOW()
    );
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
    v_transaction_id, -- UUID de la transaction
    NOW(),
    v_period_end,
    true,
    jsonb_build_object('wallet_transaction_id', v_transaction_id, 'transaction_code', v_transaction_code),
    NOW(),
    NOW()
  )
  RETURNING id INTO v_subscription_id;

  -- Enregistrer le revenu pour le PDG (avec la bonne structure)
  INSERT INTO revenus_pdg (
    id,
    source_type,
    transaction_id,
    user_id,
    amount,
    percentage_applied,
    metadata,
    created_at
  ) VALUES (
    gen_random_uuid(),
    'frais_abonnement',
    v_transaction_id,
    p_user_id,
    p_price_paid,
    100, -- 100% du montant va au PDG
    jsonb_build_object('subscription_id', v_subscription_id, 'plan_id', p_plan_id, 'billing_cycle', p_billing_cycle),
    NOW()
  );

  RETURN v_subscription_id;
END;
$$;
