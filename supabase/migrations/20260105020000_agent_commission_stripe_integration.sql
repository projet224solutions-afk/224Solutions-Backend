-- =====================================================
-- MIGRATION: Integration Commission Agents dans Paiements Stripe
-- Date: 2026-01-05
-- Description: Calcul automatique commission agents sur achats e-commerce
-- =====================================================

-- Fonction amelioree: Traiter paiement reussi avec commission agent
CREATE OR REPLACE FUNCTION process_successful_payment(
  p_transaction_id UUID
)
RETURNS BOOLEAN AS $$
DECLARE
  v_transaction stripe_transactions;
  v_seller_wallet_id UUID;
  v_platform_wallet_id UUID;
  v_platform_user_id UUID;
  v_platform_balance_before NUMERIC;
  v_platform_balance_after NUMERIC;
  v_seller_balance_before NUMERIC;
  v_seller_balance_after NUMERIC;
  v_buyer_creator_agent_id UUID;
  v_buyer_creator_type VARCHAR(20);
  v_agent_commission_amount DECIMAL(15,2);
  v_agent_commission_rate DECIMAL(5,4);
  v_agent_wallet_id UUID;
  v_agent_balance_before NUMERIC;
  v_agent_balance_after NUMERIC;
BEGIN
  -- Recuperer transaction
  SELECT * INTO v_transaction
  FROM stripe_transactions
  WHERE id = p_transaction_id;
  
  IF v_transaction.id IS NULL THEN
    RAISE EXCEPTION 'Transaction not found';
  END IF;
  
  -- Recuperer/Creer wallet vendeur
  v_seller_wallet_id := get_or_create_wallet(v_transaction.seller_id);
  
  -- Recuperer CEO/Platform wallet
  SELECT id INTO v_platform_user_id
  FROM profiles
  WHERE role = 'CEO'
  LIMIT 1;
  
  IF v_platform_user_id IS NOT NULL THEN
    v_platform_wallet_id := get_or_create_wallet(v_platform_user_id);
  END IF;
  
  -- Recuperer balances vendeur avant/apres
  SELECT available_balance - v_transaction.seller_net_amount, available_balance
    INTO v_seller_balance_before, v_seller_balance_after
    FROM wallets WHERE id = v_seller_wallet_id;
  -- Mettre a jour solde vendeur (montant net)
  UPDATE wallets
  SET 
    available_balance = available_balance + v_transaction.seller_net_amount,
    total_earned = total_earned + v_transaction.seller_net_amount,
    total_transactions = total_transactions + 1,
    updated_at = NOW()
  WHERE id = v_seller_wallet_id;
  -- Enregistrer transaction wallet vendeur
  INSERT INTO wallet_transactions (
    wallet_id,
    type,
    amount,
    currency,
    description,
    stripe_transaction_id,
    order_id,
    balance_before,
    balance_after
  ) VALUES (
    v_seller_wallet_id,
    'PAYMENT',
    v_transaction.seller_net_amount,
    v_transaction.currency,
    'Payment received from order ' || COALESCE(v_transaction.order_id::TEXT, 'N/A'),
    v_transaction.id,
    v_transaction.order_id,
    v_seller_balance_before,
    v_seller_balance_after
  );
  
  -- Mettre a jour wallet plateforme (commission)
  IF v_platform_wallet_id IS NOT NULL THEN
    SELECT available_balance - v_transaction.commission_amount, available_balance
      INTO v_platform_balance_before, v_platform_balance_after
      FROM wallets WHERE id = v_platform_wallet_id;
    UPDATE wallets
    SET 
      available_balance = available_balance + v_transaction.commission_amount,
      total_earned = total_earned + v_transaction.commission_amount,
      updated_at = NOW()
    WHERE id = v_platform_wallet_id;
    -- Enregistrer transaction wallet plateforme
    INSERT INTO wallet_transactions (
      wallet_id,
      type,
      amount,
      currency,
      description,
      stripe_transaction_id,
      balance_before,
      balance_after
    ) VALUES (
      v_platform_wallet_id,
      'COMMISSION',
      v_transaction.commission_amount,
      v_transaction.currency,
      'Platform commission from order ' || COALESCE(v_transaction.order_id::TEXT, 'N/A'),
      v_transaction.id,
      v_platform_balance_before,
      v_platform_balance_after
    );
  END IF;
  
  -- NOUVEAU: Calculer et crediter commission agent
    -- 1. Identifier agent createur du client acheteur
    SELECT creator_id, creator_type 
    INTO v_buyer_creator_agent_id, v_buyer_creator_type
    FROM agent_created_users
    WHERE user_id = v_transaction.buyer_id;
    
    IF v_buyer_creator_agent_id IS NOT NULL THEN
      -- 2. Recuperer taux commission agent depuis config
      SELECT setting_value INTO v_agent_commission_rate
      FROM commission_settings
      WHERE setting_key = 'base_user_commission';
      
      -- Par defaut 20% si non trouve
      IF v_agent_commission_rate IS NULL THEN
        v_agent_commission_rate := 0.20;
      END IF;
      
      -- 3. Calculer commission agent (% du montant net vendeur)
      v_agent_commission_amount := v_transaction.seller_net_amount * v_agent_commission_rate;
      
      -- 4. Creer/recuperer wallet agent
      v_agent_wallet_id := get_or_create_wallet(v_buyer_creator_agent_id);
      -- Recuperer balances agent avant/apres
      SELECT available_balance - v_agent_commission_amount, available_balance
        INTO v_agent_balance_before, v_agent_balance_after
        FROM wallets WHERE id = v_agent_wallet_id;
      -- 5. Crediter wallet agent
      UPDATE wallets
      SET 
        available_balance = available_balance + v_agent_commission_amount,
        total_earned = total_earned + v_agent_commission_amount,
        updated_at = NOW()
      WHERE id = v_agent_wallet_id;
      -- 6. Enregistrer commission dans agent_commissions
      INSERT INTO agent_commissions (
        commission_code,
        recipient_id,
        recipient_type,
        source_user_id,
        source_transaction_id,
        amount,
        commission_rate,
        source_type,
        calculation_details,
        status
      ) VALUES (
        'COM-' || EXTRACT(YEAR FROM NOW()) || '-' || LPAD((EXTRACT(EPOCH FROM NOW())::BIGINT % 10000000)::TEXT, 7, '0'),
        v_buyer_creator_agent_id,
        v_buyer_creator_type,
        v_transaction.buyer_id,
        v_transaction.id,
        v_agent_commission_amount,
        v_agent_commission_rate,
        'purchase',
        jsonb_build_object(
          'stripe_transaction_id', v_transaction.id,
          'product_amount', v_transaction.amount,
          'seller_net', v_transaction.seller_net_amount,
          'agent_commission_rate', v_agent_commission_rate,
          'calculation_type', 'stripe_purchase'
        ),
        'paid'
      );
      -- 7. Transaction wallet agent
      INSERT INTO wallet_transactions (
        wallet_id,
        type,
        amount,
        currency,
        description,
        stripe_transaction_id,
        balance_before,
        balance_after
      ) VALUES (
        v_agent_wallet_id,
        'AGENT_COMMISSION',
        v_agent_commission_amount,
        v_transaction.currency,
        'Commission agent - Achat client (ordre: ' || COALESCE(v_transaction.order_id::TEXT, 'N/A') || ')',
        v_transaction.id,
        v_agent_balance_before,
        v_agent_balance_after
      );
      RAISE NOTICE 'Commission agent creditee: % GNF pour agent %', v_agent_commission_amount, v_buyer_creator_agent_id;
    END IF;
  
  RETURN true;
EXCEPTION
  WHEN OTHERS THEN
    -- Logger l'erreur mais ne pas bloquer le paiement principal
    RAISE WARNING '⚠️ Erreur lors du traitement du paiement: %', SQLERRM;
    RETURN false;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Commentaire
COMMENT ON FUNCTION process_successful_payment IS 'Traite un paiement reussi: credite vendeur, plateforme ET agent createur du client';
