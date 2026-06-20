
-- =====================================================
-- CORRECTION DU SYSTÈME DE COMMISSION AGENT
-- =====================================================

-- 1. Créer une fonction unifiée pour calculer et créditer les commissions agent
CREATE OR REPLACE FUNCTION public.credit_agent_commission(
  p_user_id UUID,           -- L'utilisateur qui a effectué le paiement
  p_amount NUMERIC,         -- Montant de la transaction
  p_source_type TEXT,       -- Type: 'achat_produit', 'abonnement', 'service_pro'
  p_transaction_id UUID DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'::JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_agent_id UUID;
  v_agent RECORD;
  v_parent_agent RECORD;
  v_commission_rate NUMERIC;
  v_sub_agent_rate NUMERIC;
  v_agent_commission NUMERIC;
  v_parent_commission NUMERIC;
  v_result JSONB;
BEGIN
  -- 1. Vérifier si l'utilisateur a été créé par un agent
  SELECT agent_id INTO v_agent_id
  FROM agent_created_users
  WHERE user_id = p_user_id;
  
  IF v_agent_id IS NULL THEN
    -- Pas d'agent créateur, pas de commission
    RETURN jsonb_build_object(
      'success', true,
      'has_agent', false,
      'message', 'Utilisateur non créé par un agent'
    );
  END IF;
  
  -- 2. Récupérer les informations de l'agent
  SELECT * INTO v_agent
  FROM agents_management
  WHERE id = v_agent_id AND is_active = true;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Agent non trouvé ou inactif'
    );
  END IF;
  
  -- 3. Calculer la commission selon le type d'agent
  IF v_agent.type_agent = 'sous_agent' THEN
    -- Sous-agent: utiliser commission_sous_agent
    v_sub_agent_rate := COALESCE(v_agent.commission_sous_agent, 10);
    v_agent_commission := p_amount * (v_sub_agent_rate / 100);
    
    -- Créditer le wallet du sous-agent
    UPDATE agent_wallets
    SET balance = balance + v_agent_commission,
        updated_at = NOW()
    WHERE agent_id = v_agent_id;
    
    -- Si pas de wallet, le créer
    IF NOT FOUND THEN
      INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
      VALUES (v_agent_id, v_agent_commission, 'GNF', 'active');
    END IF;
    
    -- Logger la commission du sous-agent
    INSERT INTO agent_commissions_log (
      agent_id, amount, source_type, related_user_id, transaction_id, description
    ) VALUES (
      v_agent_id, 
      v_agent_commission, 
      p_source_type, 
      p_user_id, 
      p_transaction_id,
      'Commission sous-agent ' || v_sub_agent_rate || '% sur ' || p_source_type
    );
    
    -- Calculer commission de l'agent principal (parent)
    IF v_agent.parent_agent_id IS NOT NULL THEN
      SELECT * INTO v_parent_agent
      FROM agents_management
      WHERE id = v_agent.parent_agent_id AND is_active = true;
      
      IF FOUND THEN
        v_commission_rate := COALESCE(v_parent_agent.commission_agent_principal, 15);
        v_parent_commission := p_amount * (v_commission_rate / 100);
        
        -- Créditer le wallet de l'agent principal
        UPDATE agent_wallets
        SET balance = balance + v_parent_commission,
            updated_at = NOW()
        WHERE agent_id = v_parent_agent.id;
        
        IF NOT FOUND THEN
          INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
          VALUES (v_parent_agent.id, v_parent_commission, 'GNF', 'active');
        END IF;
        
        -- Logger la commission de l'agent principal
        INSERT INTO agent_commissions_log (
          agent_id, amount, source_type, related_user_id, transaction_id, description
        ) VALUES (
          v_parent_agent.id, 
          v_parent_commission, 
          p_source_type, 
          p_user_id, 
          p_transaction_id,
          'Commission agent principal ' || v_commission_rate || '% via sous-agent ' || v_agent.name
        );
      END IF;
    END IF;
    
    v_result := jsonb_build_object(
      'success', true,
      'has_agent', true,
      'agent_type', 'sous_agent',
      'agent_id', v_agent_id,
      'agent_name', v_agent.name,
      'agent_commission', v_agent_commission,
      'agent_rate', v_sub_agent_rate,
      'parent_agent_id', v_agent.parent_agent_id,
      'parent_commission', COALESCE(v_parent_commission, 0),
      'total_commissions', v_agent_commission + COALESCE(v_parent_commission, 0)
    );
    
  ELSE
    -- Agent principal: utiliser commission_rate ou commission_agent_principal
    v_commission_rate := COALESCE(v_agent.commission_rate, v_agent.commission_agent_principal, 20);
    v_agent_commission := p_amount * (v_commission_rate / 100);
    
    -- Créditer le wallet de l'agent
    UPDATE agent_wallets
    SET balance = balance + v_agent_commission,
        updated_at = NOW()
    WHERE agent_id = v_agent_id;
    
    IF NOT FOUND THEN
      INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
      VALUES (v_agent_id, v_agent_commission, 'GNF', 'active');
    END IF;
    
    -- Logger la commission
    INSERT INTO agent_commissions_log (
      agent_id, amount, source_type, related_user_id, transaction_id, description
    ) VALUES (
      v_agent_id, 
      v_agent_commission, 
      p_source_type, 
      p_user_id, 
      p_transaction_id,
      'Commission agent principal ' || v_commission_rate || '% sur ' || p_source_type
    );
    
    v_result := jsonb_build_object(
      'success', true,
      'has_agent', true,
      'agent_type', 'principal',
      'agent_id', v_agent_id,
      'agent_name', v_agent.name,
      'agent_commission', v_agent_commission,
      'agent_rate', v_commission_rate,
      'total_commissions', v_agent_commission
    );
  END IF;
  
  RETURN v_result;
END;
$$;

-- 2. Mettre à jour record_subscription_payment pour inclure les commissions agent
CREATE OR REPLACE FUNCTION public.record_subscription_payment(
  p_user_id uuid, 
  p_plan_id uuid, 
  p_price_paid numeric, 
  p_payment_method text DEFAULT 'wallet'::text, 
  p_payment_transaction_id text DEFAULT NULL::text, 
  p_billing_cycle text DEFAULT 'monthly'::text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_subscription_id UUID;
  v_period_end TIMESTAMP WITH TIME ZONE;
  v_wallet_id UUID;
  v_wallet_balance NUMERIC;
  v_transaction_id UUID;
  v_transaction_code TEXT;
  v_commission_result JSONB;
BEGIN
  -- Vérifier que le montant est positif pour les plans payants
  IF p_price_paid > 0 THEN
    -- Récupérer le wallet et son solde
    SELECT id, balance INTO v_wallet_id, v_wallet_balance
    FROM wallets
    WHERE user_id = p_user_id
    FOR UPDATE;
    
    IF v_wallet_id IS NULL THEN
      RAISE EXCEPTION 'Wallet non trouvé pour cet utilisateur';
    END IF;
    
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
    
    -- Enregistrer la transaction wallet
    INSERT INTO wallet_transactions (
      id, transaction_id, sender_wallet_id, receiver_wallet_id,
      amount, fee, net_amount, currency, transaction_type,
      status, description, metadata, created_at, completed_at
    ) VALUES (
      v_transaction_id, v_transaction_code, v_wallet_id, NULL,
      p_price_paid, 0, p_price_paid, 'GNF', 'subscription',
      'completed', 'Paiement abonnement ' || p_billing_cycle || ' - Plan ID: ' || p_plan_id::text,
      jsonb_build_object('plan_id', p_plan_id, 'billing_cycle', p_billing_cycle),
      NOW(), NOW()
    );
    
    -- *** NOUVEAU: Calculer et créditer la commission agent ***
    v_commission_result := credit_agent_commission(
      p_user_id,
      p_price_paid,
      'abonnement',
      v_transaction_id,
      jsonb_build_object('plan_id', p_plan_id, 'billing_cycle', p_billing_cycle)
    );
    
    RAISE NOTICE 'Commission agent result: %', v_commission_result;
  END IF;

  -- Annuler les abonnements actifs existants
  UPDATE subscriptions 
  SET status = 'cancelled', updated_at = NOW()
  WHERE user_id = p_user_id AND status = 'active';

  -- Calculer la date de fin
  CASE p_billing_cycle
    WHEN 'yearly' THEN v_period_end := NOW() + INTERVAL '1 year';
    WHEN 'quarterly' THEN v_period_end := NOW() + INTERVAL '3 months';
    ELSE v_period_end := NOW() + INTERVAL '1 month';
  END CASE;

  -- Créer le nouvel abonnement
  INSERT INTO subscriptions (
    user_id, plan_id, status, price_paid_gnf, billing_cycle,
    payment_method, payment_transaction_id, current_period_start,
    current_period_end, auto_renew, metadata, created_at, updated_at
  ) VALUES (
    p_user_id, p_plan_id, 'active', p_price_paid::INTEGER, p_billing_cycle,
    p_payment_method, v_transaction_id, NOW(), v_period_end, true,
    jsonb_build_object(
      'wallet_transaction_id', v_transaction_id, 
      'transaction_code', v_transaction_code,
      'agent_commission', v_commission_result
    ),
    NOW(), NOW()
  )
  RETURNING id INTO v_subscription_id;

  -- Enregistrer le revenu PDG
  INSERT INTO revenus_pdg (
    id, source_type, transaction_id, user_id, amount,
    percentage_applied, metadata, created_at
  ) VALUES (
    gen_random_uuid(), 'frais_abonnement', v_transaction_id, p_user_id,
    p_price_paid, 100,
    jsonb_build_object(
      'subscription_id', v_subscription_id, 
      'plan_id', p_plan_id, 
      'billing_cycle', p_billing_cycle,
      'agent_commission', v_commission_result
    ),
    NOW()
  );

  RETURN v_subscription_id;
END;
$$;

-- 3. Corriger process_successful_payment pour utiliser agent_id au lieu de creator_id
CREATE OR REPLACE FUNCTION public.process_successful_payment(p_transaction_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transaction RECORD;
  v_seller_wallet_id UUID;
  v_platform_wallet_id UUID;
  v_platform_user_id UUID;
  v_platform_balance_before NUMERIC;
  v_platform_balance_after NUMERIC;
  v_seller_balance_before NUMERIC;
  v_seller_balance_after NUMERIC;
  v_commission_result JSONB;
BEGIN
  -- Récupérer transaction
  SELECT * INTO v_transaction
  FROM stripe_transactions
  WHERE id = p_transaction_id;
  
  IF v_transaction.id IS NULL THEN
    RAISE EXCEPTION 'Transaction not found';
  END IF;
  
  -- Récupérer/Créer wallet vendeur
  v_seller_wallet_id := get_or_create_wallet(v_transaction.seller_id);
  
  -- Récupérer CEO/Platform wallet
  SELECT id INTO v_platform_user_id
  FROM profiles
  WHERE role = 'CEO'
  LIMIT 1;
  
  IF v_platform_user_id IS NOT NULL THEN
    v_platform_wallet_id := get_or_create_wallet(v_platform_user_id);
  END IF;
  
  -- Récupérer balances vendeur avant
  SELECT balance INTO v_seller_balance_before
  FROM wallets WHERE id = v_seller_wallet_id;
  
  -- Mettre à jour solde vendeur (montant net)
  UPDATE wallets
  SET 
    balance = balance + v_transaction.seller_net_amount,
    updated_at = NOW()
  WHERE id = v_seller_wallet_id;
  
  -- Récupérer balance après
  SELECT balance INTO v_seller_balance_after
  FROM wallets WHERE id = v_seller_wallet_id;
  
  -- Enregistrer transaction wallet vendeur
  INSERT INTO wallet_transactions (
    sender_wallet_id, receiver_wallet_id, amount, currency,
    description, transaction_type, status, metadata, created_at
  ) VALUES (
    NULL, v_seller_wallet_id, v_transaction.seller_net_amount, v_transaction.currency,
    'Paiement reçu commande ' || COALESCE(v_transaction.order_id::TEXT, 'N/A'),
    'payment', 'completed',
    jsonb_build_object('stripe_transaction_id', v_transaction.id, 'balance_before', v_seller_balance_before, 'balance_after', v_seller_balance_after),
    NOW()
  );
  
  -- Mettre à jour wallet plateforme (commission)
  IF v_platform_wallet_id IS NOT NULL THEN
    SELECT balance INTO v_platform_balance_before
    FROM wallets WHERE id = v_platform_wallet_id;
    
    UPDATE wallets
    SET 
      balance = balance + v_transaction.commission_amount,
      updated_at = NOW()
    WHERE id = v_platform_wallet_id;
    
    SELECT balance INTO v_platform_balance_after
    FROM wallets WHERE id = v_platform_wallet_id;
    
    INSERT INTO wallet_transactions (
      sender_wallet_id, receiver_wallet_id, amount, currency,
      description, transaction_type, status, metadata, created_at
    ) VALUES (
      NULL, v_platform_wallet_id, v_transaction.commission_amount, v_transaction.currency,
      'Commission plateforme commande ' || COALESCE(v_transaction.order_id::TEXT, 'N/A'),
      'commission', 'completed',
      jsonb_build_object('stripe_transaction_id', v_transaction.id, 'balance_before', v_platform_balance_before, 'balance_after', v_platform_balance_after),
      NOW()
    );
  END IF;
  
  -- *** CALCULER ET CRÉDITER LA COMMISSION AGENT ***
  v_commission_result := credit_agent_commission(
    v_transaction.buyer_id,
    v_transaction.amount,
    'achat_produit',
    v_transaction.id,
    jsonb_build_object('order_id', v_transaction.order_id, 'seller_id', v_transaction.seller_id)
  );
  
  RAISE NOTICE 'Commission agent pour achat: %', v_commission_result;
  
  RETURN true;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'Erreur lors du traitement du paiement: %', SQLERRM;
    RETURN false;
END;
$$;

-- 4. Créer une fonction pour les paiements wallet marketplace
CREATE OR REPLACE FUNCTION public.process_wallet_order_payment(
  p_user_id UUID,
  p_order_id UUID,
  p_amount NUMERIC,
  p_vendor_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user_wallet_id UUID;
  v_user_balance NUMERIC;
  v_vendor_wallet_id UUID;
  v_transaction_id UUID;
  v_platform_fee NUMERIC;
  v_vendor_net NUMERIC;
  v_commission_result JSONB;
BEGIN
  -- Récupérer le wallet utilisateur
  SELECT id, balance INTO v_user_wallet_id, v_user_balance
  FROM wallets
  WHERE user_id = p_user_id
  FOR UPDATE;
  
  IF v_user_wallet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet utilisateur non trouvé');
  END IF;
  
  IF v_user_balance < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solde insuffisant');
  END IF;
  
  -- Récupérer user_id du vendeur
  DECLARE v_vendor_user_id UUID;
  BEGIN
    SELECT user_id INTO v_vendor_user_id FROM vendors WHERE id = p_vendor_id;
    IF v_vendor_user_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'Vendeur non trouvé');
    END IF;
    
    -- Récupérer ou créer wallet vendeur
    SELECT id INTO v_vendor_wallet_id FROM wallets WHERE user_id = v_vendor_user_id;
    IF v_vendor_wallet_id IS NULL THEN
      INSERT INTO wallets (user_id, balance, currency)
      VALUES (v_vendor_user_id, 0, 'GNF')
      RETURNING id INTO v_vendor_wallet_id;
    END IF;
  END;
  
  -- Calculer les frais (2.5% plateforme)
  v_platform_fee := p_amount * 0.025;
  v_vendor_net := p_amount - v_platform_fee;
  v_transaction_id := gen_random_uuid();
  
  -- Débiter l'utilisateur
  UPDATE wallets SET balance = balance - p_amount, updated_at = NOW()
  WHERE id = v_user_wallet_id;
  
  -- Créditer le vendeur
  UPDATE wallets SET balance = balance + v_vendor_net, updated_at = NOW()
  WHERE id = v_vendor_wallet_id;
  
  -- Enregistrer la transaction
  INSERT INTO wallet_transactions (
    id, sender_wallet_id, receiver_wallet_id, amount, fee, net_amount,
    currency, transaction_type, status, description, metadata, created_at, completed_at
  ) VALUES (
    v_transaction_id, v_user_wallet_id, v_vendor_wallet_id, p_amount, v_platform_fee, v_vendor_net,
    'GNF', 'purchase', 'completed', 'Paiement commande #' || p_order_id::text,
    jsonb_build_object('order_id', p_order_id, 'vendor_id', p_vendor_id),
    NOW(), NOW()
  );
  
  -- *** CALCULER ET CRÉDITER LA COMMISSION AGENT ***
  v_commission_result := credit_agent_commission(
    p_user_id,
    p_amount,
    'achat_produit',
    v_transaction_id,
    jsonb_build_object('order_id', p_order_id, 'vendor_id', p_vendor_id)
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'amount', p_amount,
    'platform_fee', v_platform_fee,
    'vendor_net', v_vendor_net,
    'agent_commission', v_commission_result
  );
END;
$$;

-- 5. Créer fonction pour commissions sur services professionnels
CREATE OR REPLACE FUNCTION public.process_professional_service_payment(
  p_user_id UUID,
  p_service_id UUID,
  p_amount NUMERIC,
  p_service_type TEXT DEFAULT 'service_pro'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transaction_id UUID;
  v_commission_result JSONB;
BEGIN
  v_transaction_id := gen_random_uuid();
  
  -- Calculer et créditer la commission agent
  v_commission_result := credit_agent_commission(
    p_user_id,
    p_amount,
    p_service_type,
    v_transaction_id,
    jsonb_build_object('service_id', p_service_id, 'service_type', p_service_type)
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'amount', p_amount,
    'agent_commission', v_commission_result
  );
END;
$$;
