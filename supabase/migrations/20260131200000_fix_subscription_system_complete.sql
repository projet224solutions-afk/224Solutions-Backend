-- ============================================
-- CORRECTION COMPLÈTE DU SYSTÈME D'ABONNEMENT
-- 224SOLUTIONS - 31 Janvier 2026
-- ============================================
-- Problèmes identifiés:
-- 1. subscribe_user() ne débite PAS le wallet (migration écrasée)
-- 2. record_subscription_payment() ne débite PAS non plus
-- 3. Deux systèmes d'abonnement coexistent avec logique différente
-- Solution: Unifier avec débit wallet automatique
-- ============================================

-- ============================================
-- ÉTAPE 1: FONCTION subscribe_user AVEC DÉBIT WALLET
-- ============================================

DROP FUNCTION IF EXISTS public.subscribe_user(UUID, UUID, TEXT, TEXT, TEXT);

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
  v_wallet_transaction_id UUID;
BEGIN
  -- 1. Récupérer les infos du plan
  SELECT
    CASE
      WHEN p_billing_cycle = 'yearly' THEN COALESCE(yearly_price_gnf, monthly_price_gnf * 12)
      WHEN p_billing_cycle = 'quarterly' THEN monthly_price_gnf * 3
      ELSE monthly_price_gnf
    END,
    CASE
      WHEN p_billing_cycle = 'yearly' THEN COALESCE(duration_days, 30) * 12
      WHEN p_billing_cycle = 'quarterly' THEN COALESCE(duration_days, 30) * 3
      ELSE COALESCE(duration_days, 30)
    END,
    name,
    COALESCE(user_role, 'vendeur')
  INTO v_price, v_duration_days, v_plan_name, v_user_role
  FROM public.plans
  WHERE id = p_plan_id AND is_active = true;

  IF v_price IS NULL THEN
    RAISE EXCEPTION 'Plan non trouvé ou inactif (ID: %)', p_plan_id;
  END IF;

  -- 2. VÉRIFIER ET DÉBITER LE WALLET (si payment_method = wallet)
  IF p_payment_method = 'wallet' THEN
    -- Récupérer le wallet GNF de l'utilisateur
    SELECT id, COALESCE(balance, 0)::INTEGER
    INTO v_wallet_id, v_wallet_balance
    FROM public.wallets
    WHERE user_id = p_user_id
      AND currency = 'GNF'
    LIMIT 1;

    IF v_wallet_id IS NULL THEN
      -- Créer un wallet si inexistant
      INSERT INTO public.wallets (user_id, balance, currency)
      VALUES (p_user_id, 0, 'GNF')
      RETURNING id, 0 INTO v_wallet_id, v_wallet_balance;
    END IF;

    -- Vérifier le solde
    IF v_wallet_balance < v_price THEN
      RAISE EXCEPTION 'Solde insuffisant: % GNF disponible, % GNF requis pour l''abonnement %',
        v_wallet_balance, v_price, v_plan_name;
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
      balance_before,
      balance_after,
      description,
      status,
      metadata,
      created_at
    ) VALUES (
      v_wallet_id,
      'subscription',
      v_price,
      v_wallet_balance,
      v_wallet_balance - v_price,
      'Abonnement ' || v_plan_name || ' (' || p_billing_cycle || ')',
      'completed',
      jsonb_build_object(
        'plan_id', p_plan_id,
        'plan_name', v_plan_name,
        'billing_cycle', p_billing_cycle,
        'user_role', v_user_role,
        'payment_method', p_payment_method
      ),
      NOW()
    )
    RETURNING id INTO v_wallet_transaction_id;

    RAISE NOTICE 'Wallet débité: % GNF pour abonnement %', v_price, v_plan_name;
  END IF;

  -- 3. Calculer la date de fin
  v_period_end := NOW() + (v_duration_days || ' days')::INTERVAL;

  -- 4. Désactiver les anciens abonnements actifs de l'utilisateur
  UPDATE public.subscriptions
  SET status = 'expired',
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
    started_at,
    current_period_end,
    auto_renew,
    payment_method,
    payment_transaction_id,
    metadata,
    created_at,
    updated_at
  ) VALUES (
    p_user_id,
    p_plan_id,
    v_price,
    p_billing_cycle,
    'active',
    NOW(),
    v_period_end,
    true,
    p_payment_method,
    COALESCE(p_transaction_id, v_wallet_transaction_id::TEXT),
    jsonb_build_object(
      'migrated', false,
      'plan_type', v_user_role,
      'wallet_transaction_id', v_wallet_transaction_id,
      'created_by', 'subscribe_user_v2'
    ),
    NOW(),
    NOW()
  )
  RETURNING id INTO v_subscription_id;

  -- 6. Enregistrer le revenu PDG (100% du montant d'abonnement)
  INSERT INTO public.revenus_pdg (
    source_type,
    transaction_id,
    user_id,
    amount,
    percentage_applied,
    description,
    metadata,
    created_at
  ) VALUES (
    'frais_abonnement',
    v_subscription_id,
    p_user_id,
    v_price,
    100,
    'Abonnement ' || v_plan_name || ' (' || p_billing_cycle || ')',
    jsonb_build_object(
      'subscription_id', v_subscription_id,
      'plan_id', p_plan_id,
      'plan_name', v_plan_name,
      'billing_cycle', p_billing_cycle,
      'user_role', v_user_role,
      'wallet_transaction_id', v_wallet_transaction_id
    ),
    NOW()
  );

  RAISE NOTICE 'Abonnement créé: ID=%, Plan=%, Prix=% GNF, Expire=%',
    v_subscription_id, v_plan_name, v_price, v_period_end;

  RETURN v_subscription_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ============================================
-- ÉTAPE 2: FONCTION record_subscription_payment (WRAPPER)
-- ============================================

DROP FUNCTION IF EXISTS public.record_subscription_payment(UUID, UUID, INTEGER, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.record_subscription_payment(UUID, UUID, NUMERIC, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.record_subscription_payment(UUID, UUID, INTEGER, VARCHAR, UUID, VARCHAR);
DROP FUNCTION IF EXISTS public.record_subscription_payment(UUID, UUID, NUMERIC, TEXT, UUID, TEXT);

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
BEGIN
  -- Utiliser la fonction subscribe_user qui gère le débit wallet
  RETURN subscribe_user(
    p_user_id,
    p_plan_id,
    p_payment_method,
    p_payment_transaction_id,
    p_billing_cycle
  );
END;
$$;

-- ============================================
-- ÉTAPE 3: FONCTION get_active_subscription (AMÉLIORÉE)
-- ============================================

DROP FUNCTION IF EXISTS public.get_active_subscription(UUID);

CREATE OR REPLACE FUNCTION public.get_active_subscription(p_user_id UUID)
RETURNS TABLE (
  subscription_id UUID,
  plan_id UUID,
  plan_name VARCHAR,
  plan_display_name VARCHAR,
  status VARCHAR,
  current_period_end TIMESTAMP WITH TIME ZONE,
  auto_renew BOOLEAN,
  price_paid INTEGER,
  billing_cycle VARCHAR,
  user_role TEXT,
  duration_days INTEGER,
  max_products INTEGER,
  max_images_per_product INTEGER,
  analytics_access BOOLEAN,
  priority_support BOOLEAN,
  featured_products BOOLEAN,
  api_access BOOLEAN,
  custom_branding BOOLEAN,
  features JSONB
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    s.id as subscription_id,
    p.id as plan_id,
    p.name as plan_name,
    p.display_name as plan_display_name,
    s.status,
    s.current_period_end,
    s.auto_renew,
    s.price_paid_gnf as price_paid,
    s.billing_cycle,
    COALESCE(p.user_role, 'vendeur') as user_role,
    COALESCE(p.duration_days, 30) as duration_days,
    p.max_products,
    p.max_images_per_product,
    COALESCE(p.analytics_access, false) as analytics_access,
    COALESCE(p.priority_support, false) as priority_support,
    COALESCE(p.featured_products, false) as featured_products,
    COALESCE(p.api_access, false) as api_access,
    COALESCE(p.custom_branding, false) as custom_branding,
    COALESCE(p.features, '[]'::jsonb) as features
  FROM public.subscriptions s
  INNER JOIN public.plans p ON s.plan_id = p.id
  WHERE s.user_id = p_user_id
    AND s.status = 'active'
    AND s.current_period_end > NOW()
  ORDER BY s.current_period_end DESC
  LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ============================================
-- ÉTAPE 4: FONCTION has_active_subscription
-- ============================================

CREATE OR REPLACE FUNCTION public.has_active_subscription(p_user_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.subscriptions
    WHERE user_id = p_user_id
      AND status = 'active'
      AND current_period_end > NOW()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ============================================
-- ÉTAPE 5: VÉRIFIER/AJOUTER COLONNES MANQUANTES
-- ============================================

-- Ajouter started_at si manquant
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'subscriptions' AND column_name = 'started_at') THEN
    ALTER TABLE public.subscriptions ADD COLUMN started_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();
  END IF;
END $$;

-- Ajouter current_period_start si manquant
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'subscriptions' AND column_name = 'current_period_start') THEN
    ALTER TABLE public.subscriptions ADD COLUMN current_period_start TIMESTAMP WITH TIME ZONE DEFAULT NOW();
  END IF;
END $$;

-- ============================================
-- ÉTAPE 6: GRANT PERMISSIONS
-- ============================================

GRANT EXECUTE ON FUNCTION public.subscribe_user(UUID, UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.subscribe_user(UUID, UUID, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.record_subscription_payment(UUID, UUID, NUMERIC, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_subscription_payment(UUID, UUID, NUMERIC, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_active_subscription(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_active_subscription(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.has_active_subscription(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_active_subscription(UUID) TO service_role;

-- ============================================
-- ÉTAPE 7: COMMENTAIRES
-- ============================================

COMMENT ON FUNCTION public.subscribe_user IS 'Crée un abonnement avec débit automatique du wallet. Vérifie le solde, débite, crée l''abonnement et enregistre le revenu PDG.';
COMMENT ON FUNCTION public.record_subscription_payment IS 'Wrapper pour subscribe_user - maintient la compatibilité avec l''ancien code.';
COMMENT ON FUNCTION public.get_active_subscription IS 'Retourne l''abonnement actif de l''utilisateur avec toutes les infos du plan.';
COMMENT ON FUNCTION public.has_active_subscription IS 'Vérifie rapidement si l''utilisateur a un abonnement actif non expiré.';

-- ============================================
-- MESSAGE DE CONFIRMATION
-- ============================================

DO $$
BEGIN
  RAISE NOTICE '✅ Système d''abonnement corrigé avec succès';
  RAISE NOTICE '💰 subscribe_user() débite maintenant le wallet automatiquement';
  RAISE NOTICE '🔄 record_subscription_payment() utilise subscribe_user()';
  RAISE NOTICE '📊 get_active_subscription() retourne toutes les infos du plan';
END $$;
