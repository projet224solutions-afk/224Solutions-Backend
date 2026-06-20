-- Correction: Ajouter la déduction du wallet dans subscribe_user
CREATE OR REPLACE FUNCTION public.subscribe_user(
  p_user_id UUID,
  p_plan_id UUID,
  p_payment_method TEXT DEFAULT 'wallet',
  p_transaction_id TEXT DEFAULT NULL,
  p_billing_cycle TEXT DEFAULT 'monthly'
)
RETURNS UUID AS $$
DECLARE
  v_subscription_id UUID;
  v_price INTEGER;
  v_duration_days INTEGER;
  v_period_end TIMESTAMP WITH TIME ZONE;
  v_plan_name TEXT;
  v_user_role TEXT;
  v_wallet_id UUID;
  v_wallet_balance NUMERIC;
BEGIN
  -- Récupérer les infos du plan
  SELECT 
    CASE 
      WHEN p_billing_cycle = 'yearly' THEN COALESCE(yearly_price_gnf, monthly_price_gnf * 12)
      ELSE monthly_price_gnf 
    END,
    CASE 
      WHEN p_billing_cycle = 'yearly' THEN duration_days * 12
      ELSE duration_days 
    END,
    name,
    user_role
  INTO v_price, v_duration_days, v_plan_name, v_user_role
  FROM public.plans
  WHERE id = p_plan_id AND is_active = true;
  
  IF v_price IS NULL THEN
    RAISE EXCEPTION 'Plan non trouvé ou inactif';
  END IF;
  
  -- Vérifier et déduire du wallet si paiement par wallet
  IF p_payment_method = 'wallet' THEN
    -- Récupérer le wallet de l'utilisateur
    SELECT id, balance INTO v_wallet_id, v_wallet_balance
    FROM public.wallets
    WHERE user_id = p_user_id
    FOR UPDATE; -- Verrouiller pour éviter les conditions de course
    
    IF v_wallet_id IS NULL THEN
      RAISE EXCEPTION 'Wallet non trouvé pour cet utilisateur';
    END IF;
    
    IF v_wallet_balance < v_price THEN
      RAISE EXCEPTION 'Solde insuffisant. Solde: % GNF, Prix: % GNF', v_wallet_balance, v_price;
    END IF;
    
    -- Déduire le montant du wallet
    UPDATE public.wallets
    SET balance = balance - v_price,
        updated_at = NOW()
    WHERE id = v_wallet_id;
    
    -- Enregistrer la transaction wallet
    INSERT INTO public.wallet_logs (
      wallet_id,
      action,
      amount,
      balance_after,
      description,
      metadata
    ) VALUES (
      v_wallet_id,
      'debit',
      v_price,
      v_wallet_balance - v_price,
      'Achat abonnement ' || v_plan_name || ' (' || p_billing_cycle || ')',
      jsonb_build_object(
        'plan_id', p_plan_id,
        'plan_name', v_plan_name,
        'billing_cycle', p_billing_cycle
      )
    );
  END IF;
  
  -- Calculer la date de fin
  v_period_end := NOW() + (v_duration_days || ' days')::INTERVAL;
  
  -- Désactiver les anciens abonnements de l'utilisateur
  UPDATE public.subscriptions 
  SET status = 'cancelled', 
      auto_renew = false,
      updated_at = NOW()
  WHERE user_id = p_user_id 
    AND status = 'active';
  
  -- Créer le nouvel abonnement
  INSERT INTO public.subscriptions (
    user_id,
    plan_id,
    price_paid_gnf,
    billing_cycle,
    status,
    current_period_end,
    payment_method,
    payment_transaction_id,
    metadata
  ) VALUES (
    p_user_id,
    p_plan_id,
    v_price,
    p_billing_cycle,
    'active',
    v_period_end,
    p_payment_method,
    p_transaction_id,
    jsonb_build_object('migrated', false, 'plan_type', v_user_role)
  )
  RETURNING id INTO v_subscription_id;
  
  -- Enregistrer le revenu PDG (100% du montant)
  INSERT INTO public.revenus_pdg (
    source_type,
    transaction_id,
    user_id,
    amount,
    description,
    metadata
  ) VALUES (
    'frais_abonnement',
    v_subscription_id,
    p_user_id,
    v_price,
    'Abonnement ' || v_plan_name || ' (' || p_billing_cycle || ')',
    jsonb_build_object(
      'subscription_id', v_subscription_id,
      'plan_id', p_plan_id,
      'plan_name', v_plan_name,
      'billing_cycle', p_billing_cycle,
      'user_role', v_user_role
    )
  );
  
  RETURN v_subscription_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant permissions
GRANT EXECUTE ON FUNCTION public.subscribe_user(UUID, UUID, TEXT, TEXT, TEXT) TO authenticated;
