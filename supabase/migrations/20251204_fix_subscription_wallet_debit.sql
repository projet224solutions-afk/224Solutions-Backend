-- ============================================
-- CORRECTION CRITIQUE: DÉBIT WALLET ABONNEMENTS VENDEURS
-- ============================================
-- Problème: subscribe_user() crée l'abonnement SANS débiter le wallet
-- Solution: Ajouter débit wallet + vérification solde dans subscribe_user()
-- ============================================

-- Supprimer l'ancienne fonction
DROP FUNCTION IF EXISTS public.subscribe_user(UUID, UUID, TEXT, TEXT, TEXT);

-- Recréer la fonction avec débit wallet
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
  v_wallet_balance INTEGER;
  v_transaction_id UUID;
BEGIN
  -- 1. Récupérer les infos du plan
  SELECT 
    CASE 
      WHEN p_billing_cycle = 'yearly' THEN COALESCE(yearly_price_gnf, monthly_price_gnf * 12)
      WHEN p_billing_cycle = 'quarterly' THEN monthly_price_gnf * 3
      ELSE monthly_price_gnf 
    END,
    CASE 
      WHEN p_billing_cycle = 'yearly' THEN duration_days * 12
      WHEN p_billing_cycle = 'quarterly' THEN duration_days * 3
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

  -- 2. VÉRIFIER ET DÉBITER LE WALLET (si payment_method = wallet)
  IF p_payment_method = 'wallet' THEN
    -- Récupérer le wallet de l'utilisateur
    SELECT id, balance 
    INTO v_wallet_id, v_wallet_balance
    FROM public.wallets
    WHERE user_id = p_user_id
    LIMIT 1;

    IF v_wallet_id IS NULL THEN
      RAISE EXCEPTION 'Wallet non trouvé pour cet utilisateur';
    END IF;

    -- Vérifier le solde
    IF v_wallet_balance < v_price THEN
      RAISE EXCEPTION 'Solde insuffisant: % GNF disponible, % GNF requis', 
        v_wallet_balance, v_price;
    END IF;

    -- Débiter le wallet
    UPDATE public.wallets
    SET balance = balance - v_price,
        updated_at = NOW()
    WHERE id = v_wallet_id;

    -- Créer la transaction wallet
    INSERT INTO public.wallet_transactions (
      wallet_id,
      transaction_type,
      amount,
      description,
      metadata
    ) VALUES (
      v_wallet_id,
      'debit',
      v_price,
      'Abonnement ' || v_plan_name || ' (' || p_billing_cycle || ')',
      jsonb_build_object(
        'plan_id', p_plan_id,
        'plan_name', v_plan_name,
        'billing_cycle', p_billing_cycle,
        'user_role', v_user_role,
        'payment_method', p_payment_method
      )
    )
    RETURNING id INTO v_transaction_id;
  END IF;
  
  -- 3. Calculer la date de fin
  v_period_end := NOW() + (v_duration_days || ' days')::INTERVAL;
  
  -- 4. Désactiver les anciens abonnements de l'utilisateur
  UPDATE public.subscriptions 
  SET status = 'cancelled', 
      auto_renew = false,
      updated_at = NOW()
  WHERE user_id = p_user_id 
    AND status = 'active';
  
  -- 5. Créer le nouvel abonnement
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
    COALESCE(p_transaction_id, v_transaction_id::TEXT),
    jsonb_build_object(
      'migrated', false, 
      'plan_type', v_user_role,
      'wallet_transaction_id', v_transaction_id
    )
  )
  RETURNING id INTO v_subscription_id;
  
  -- 6. Enregistrer le revenu PDG (100% du montant)
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
      'user_role', v_user_role,
      'wallet_transaction_id', v_transaction_id
    )
  );
  
  RETURN v_subscription_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- COMMENTAIRE EXPLICATIF
-- ============================================

COMMENT ON FUNCTION public.subscribe_user IS 'Fonction universelle pour créer un abonnement avec débit automatique du wallet. Vérifie le solde, débite le montant, crée l\'abonnement et enregistre le revenu PDG.';

-- ============================================
-- GRANT PERMISSIONS
-- ============================================

GRANT EXECUTE ON FUNCTION public.subscribe_user TO authenticated;
GRANT EXECUTE ON FUNCTION public.subscribe_user TO service_role;
