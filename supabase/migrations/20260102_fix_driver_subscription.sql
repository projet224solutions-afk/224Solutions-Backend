-- FIX: Abonnement Taxi-Moto et Offre PDG
-- Date: 2025-01-02
-- Corrections des problèmes d'abonnement

-- 1. Ajouter 'pdg_gift' et 'custom' aux payment_methods autorisés
ALTER TABLE driver_subscriptions
DROP CONSTRAINT IF EXISTS driver_subscriptions_payment_method_check;

ALTER TABLE driver_subscriptions
ADD CONSTRAINT driver_subscriptions_payment_method_check
CHECK (payment_method IN ('wallet', 'mobile_money', 'card', 'pdg_gift', 'custom'));

-- 2. Vérifier que billing_cycle existe (devrait déjà exister depuis migration 20251116)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'driver_subscriptions' 
    AND column_name = 'billing_cycle'
  ) THEN
    ALTER TABLE driver_subscriptions
    ADD COLUMN billing_cycle TEXT DEFAULT 'monthly' CHECK (billing_cycle IN ('monthly', 'yearly', 'custom'));
  END IF;
END$$;

-- 3. Vérifier que yearly_price existe dans config
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'driver_subscription_config' 
    AND column_name = 'yearly_price'
  ) THEN
    ALTER TABLE driver_subscription_config
    ADD COLUMN yearly_price NUMERIC(10,2);
    
    -- Calculer yearly_price pour config existante (12 mois - 5% de réduction)
    UPDATE driver_subscription_config
    SET yearly_price = ROUND(price * 12 * 0.95, 2)
    WHERE yearly_price IS NULL;
  END IF;
END$$;

-- 4. Améliorer la fonction subscribe_driver avec meilleure gestion d'erreurs
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
  -- Validation des paramètres
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'User ID requis';
  END IF;
  
  IF p_type NOT IN ('taxi', 'livreur') THEN
    RAISE EXCEPTION 'Type invalide. Doit être taxi ou livreur';
  END IF;

  -- Récupérer le prix et la durée selon le billing_cycle
  IF p_billing_cycle = 'yearly' THEN
    SELECT COALESCE(yearly_price, price * 12), 365 INTO v_price, v_duration_days
    FROM driver_subscription_config
    WHERE subscription_type IN ('both', p_type) AND is_active = TRUE
    ORDER BY subscription_type = 'both' DESC
    LIMIT 1;
  ELSE
    SELECT price, duration_days INTO v_price, v_duration_days
    FROM driver_subscription_config
    WHERE subscription_type IN ('both', p_type) AND is_active = TRUE
    ORDER BY subscription_type = 'both' DESC
    LIMIT 1;
  END IF;
  
  -- Si pas de config, utiliser valeurs par défaut
  IF v_price IS NULL THEN
    v_price := 50000;
    v_duration_days := 30;
    RAISE NOTICE 'Utilisation configuration par défaut: % GNF pour % jours', v_price, v_duration_days;
  END IF;
  
  -- Si paiement par wallet, vérifier et débiter le solde
  IF p_payment_method = 'wallet' THEN
    -- Vérifier le solde du wallet
    SELECT balance INTO v_wallet_balance
    FROM wallets
    WHERE user_id = p_user_id
    FOR UPDATE; -- Lock pour éviter les race conditions
    
    IF v_wallet_balance IS NULL THEN
      -- Créer wallet avec solde 0 si inexistant
      INSERT INTO wallets (user_id, balance, currency)
      VALUES (p_user_id, 0, 'GNF')
      ON CONFLICT (user_id) DO NOTHING;
      
      v_wallet_balance := 0;
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
    -- Pour autres méthodes (pdg_gift, mobile_money, etc.)
    v_transaction_code := COALESCE(p_transaction_id, 'SUB-' || EXTRACT(EPOCH FROM NOW())::BIGINT || '-' || SUBSTRING(p_user_id::TEXT, 1, 8));
    v_wallet_balance := 0;
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
      'new_balance', CASE WHEN p_payment_method = 'wallet' THEN v_wallet_balance - v_price ELSE NULL END
    )
  ) RETURNING id INTO v_subscription_id;
  
  -- Enregistrer le revenu (sauf pour pdg_gift gratuit)
  IF v_price > 0 THEN
    INSERT INTO driver_subscription_revenues (
      subscription_id, user_id, amount, payment_method, transaction_id
    ) VALUES (
      v_subscription_id, p_user_id, v_price, p_payment_method, v_transaction_code
    );
  END IF;
  
  RETURN v_subscription_id;
END;
$$;

-- 5. Créer fonction helper pour offrir abonnement (PDG)
CREATE OR REPLACE FUNCTION pdg_offer_subscription(
  p_user_id UUID,
  p_type TEXT,
  p_days INTEGER DEFAULT 30
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subscription_id UUID;
  v_end_date TIMESTAMPTZ;
BEGIN
  -- Validation
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'User ID requis';
  END IF;
  
  IF p_type NOT IN ('taxi', 'livreur') THEN
    RAISE EXCEPTION 'Type invalide. Doit être taxi ou livreur';
  END IF;
  
  IF p_days <= 0 OR p_days > 365 THEN
    RAISE EXCEPTION 'Durée invalide. Doit être entre 1 et 365 jours';
  END IF;
  
  -- Calculer date de fin
  v_end_date := NOW() + (p_days || ' days')::INTERVAL;
  
  -- Désactiver anciens abonnements
  UPDATE driver_subscriptions
  SET status = 'expired', updated_at = NOW()
  WHERE user_id = p_user_id AND status = 'active';
  
  -- Créer abonnement gratuit offert par PDG
  INSERT INTO driver_subscriptions (
    user_id, type, price, status, start_date, end_date,
    payment_method, transaction_id, billing_cycle, metadata
  ) VALUES (
    p_user_id, p_type, 0, 'active', NOW(), v_end_date,
    'pdg_gift', 'GIFT-PDG-' || EXTRACT(EPOCH FROM NOW())::BIGINT, 'custom',
    jsonb_build_object(
      'offered_by_pdg', TRUE,
      'days_offered', p_days,
      'offered_at', NOW()
    )
  ) RETURNING id INTO v_subscription_id;
  
  RETURN v_subscription_id;
END;
$$;

-- 6. Fonction pour vérifier la santé du système d'abonnement
CREATE OR REPLACE FUNCTION check_subscription_system_health()
RETURNS TABLE (
  check_name TEXT,
  status TEXT,
  details TEXT
) AS $$
BEGIN
  -- Vérifier config active
  RETURN QUERY
  SELECT 
    'Configuration active'::TEXT,
    CASE WHEN COUNT(*) > 0 THEN 'OK' ELSE 'ERROR' END::TEXT,
    'Configs actives: ' || COUNT(*)::TEXT
  FROM driver_subscription_config
  WHERE is_active = TRUE;
  
  -- Vérifier abonnements actifs
  RETURN QUERY
  SELECT 
    'Abonnements actifs'::TEXT,
    'INFO'::TEXT,
    'Total: ' || COUNT(*)::TEXT
  FROM driver_subscriptions
  WHERE status = 'active' AND end_date > NOW();
  
  -- Vérifier abonnements expirés non marqués
  RETURN QUERY
  SELECT 
    'Abonnements expirés non marqués'::TEXT,
    CASE WHEN COUNT(*) > 0 THEN 'WARNING' ELSE 'OK' END::TEXT,
    'À corriger: ' || COUNT(*)::TEXT
  FROM driver_subscriptions
  WHERE status = 'active' AND end_date <= NOW();
  
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Vérifier et corriger la configuration par défaut
INSERT INTO driver_subscription_config (subscription_type, price, duration_days, yearly_price, is_active)
VALUES ('both', 50000, 30, 570000, TRUE)
ON CONFLICT (subscription_type) DO UPDATE
SET 
  yearly_price = COALESCE(driver_subscription_config.yearly_price, EXCLUDED.yearly_price),
  updated_at = NOW()
WHERE driver_subscription_config.yearly_price IS NULL;

-- 8. Commentaires pour documentation
COMMENT ON FUNCTION subscribe_driver IS 'Crée ou renouvelle un abonnement conducteur avec paiement wallet. Gère automatiquement le débit, les transactions et les revenus.';
COMMENT ON FUNCTION pdg_offer_subscription IS 'Permet au PDG d''offrir gratuitement un abonnement à un conducteur pour une durée personnalisée.';
COMMENT ON FUNCTION check_subscription_system_health IS 'Diagnostic de santé du système d''abonnement. Retourne les checks de configuration et d''état.';
