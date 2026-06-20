-- =====================================================
-- STRIPE PAYMENT SYSTEM v1.0
-- Système de paiement Stripe avec wallet interne
-- 224SOLUTIONS
-- =====================================================

-- =====================================================
-- CONFIGURATION STRIPE
-- =====================================================

CREATE TABLE IF NOT EXISTS stripe_config (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Configuration globale
  platform_commission_rate DECIMAL(5,2) DEFAULT 10.00 CHECK (platform_commission_rate >= 0 AND platform_commission_rate <= 100),
  stripe_publishable_key TEXT,
  stripe_secret_key TEXT, -- Chiffré en production
  stripe_webhook_secret TEXT, -- Chiffré en production
  
  -- Devises supportées
  default_currency TEXT DEFAULT 'GNF',
  supported_currencies JSONB DEFAULT '["GNF", "USD", "EUR"]'::jsonb,
  
  -- Configuration 3D Secure
  require_3d_secure BOOLEAN DEFAULT true,
  
  -- Configuration abonnements
  enable_subscriptions BOOLEAN DEFAULT false,
  
  -- Métadonnées
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Un seul enregistrement de config
CREATE UNIQUE INDEX idx_stripe_config_singleton ON stripe_config ((true));

-- =====================================================
-- TRANSACTIONS STRIPE
-- =====================================================

CREATE TYPE payment_status AS ENUM (
  'PENDING',
  'PROCESSING',
  'SUCCEEDED',
  'FAILED',
  'CANCELED',
  'REFUNDED',
  'DISPUTED'
);

CREATE TYPE transaction_type AS ENUM (
  'PAYMENT',
  'COMMISSION',
  'WITHDRAWAL',
  'REFUND',
  'CHARGEBACK'
);

CREATE TABLE IF NOT EXISTS stripe_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Identifiants Stripe
  stripe_payment_intent_id TEXT UNIQUE,
  stripe_charge_id TEXT,
  
  -- Utilisateurs
  buyer_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  seller_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  
  -- Montants (en centimes/unités minimales)
  amount INTEGER NOT NULL CHECK (amount > 0),
  currency TEXT DEFAULT 'GNF',
  
  -- Commission plateforme
  commission_rate DECIMAL(5,2) NOT NULL,
  commission_amount INTEGER NOT NULL CHECK (commission_amount >= 0),
  seller_net_amount INTEGER NOT NULL CHECK (seller_net_amount >= 0),
  
  -- Statut
  status payment_status DEFAULT 'PENDING',
  
  -- Metadata
  order_id UUID,
  service_id UUID,
  product_id UUID,
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Informations paiement
  payment_method TEXT, -- card, mobile_money, bank_transfer
  last4 TEXT, -- 4 derniers chiffres carte
  card_brand TEXT, -- visa, mastercard, etc.
  
  -- 3D Secure
  requires_3ds BOOLEAN DEFAULT false,
  three_ds_status TEXT,
  
  -- Erreurs
  error_code TEXT,
  error_message TEXT,
  
  -- Timestamps
  paid_at TIMESTAMPTZ,
  refunded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index pour performance
CREATE INDEX idx_stripe_transactions_buyer_id ON stripe_transactions(buyer_id);
CREATE INDEX idx_stripe_transactions_seller_id ON stripe_transactions(seller_id);
CREATE INDEX idx_stripe_transactions_status ON stripe_transactions(status);
CREATE INDEX idx_stripe_transactions_payment_intent ON stripe_transactions(stripe_payment_intent_id);
CREATE INDEX idx_stripe_transactions_order_id ON stripe_transactions(order_id);

-- =====================================================
-- WALLET INTERNE
-- =====================================================

CREATE TYPE wallet_status AS ENUM (
  'ACTIVE',
  'FROZEN',
  'SUSPENDED'
);

CREATE TABLE IF NOT EXISTS wallets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Propriétaire du wallet
  user_id UUID NOT NULL UNIQUE REFERENCES profiles(id) ON DELETE CASCADE,
  
  -- Soldes (en centimes/unités minimales)
  available_balance INTEGER DEFAULT 0 CHECK (available_balance >= 0),
  pending_balance INTEGER DEFAULT 0 CHECK (pending_balance >= 0),
  frozen_balance INTEGER DEFAULT 0 CHECK (frozen_balance >= 0),
  
  -- Devise
  currency TEXT DEFAULT 'GNF',
  
  -- Statut
  status wallet_status DEFAULT 'ACTIVE',
  
  -- Métadonnées
  total_earned INTEGER DEFAULT 0,
  total_withdrawn INTEGER DEFAULT 0,
  total_transactions INTEGER DEFAULT 0,
  
  -- KYC / Vérification (pour retraits)
  is_verified BOOLEAN DEFAULT false,
  verification_level TEXT, -- basic, intermediate, advanced
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index
CREATE INDEX idx_wallets_user_id ON wallets(user_id);
CREATE INDEX idx_wallets_status ON wallets(status);

-- =====================================================
-- HISTORIQUE TRANSACTIONS WALLET
-- =====================================================

CREATE TABLE IF NOT EXISTS wallet_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Wallet
  wallet_id UUID NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
  
  -- Type et montant
  type transaction_type NOT NULL,
  amount INTEGER NOT NULL,
  currency TEXT DEFAULT 'GNF',
  
  -- Description
  description TEXT,
  
  -- Référence transaction Stripe (si applicable)
  stripe_transaction_id UUID REFERENCES stripe_transactions(id),
  
  -- Référence commande/service
  order_id UUID,
  service_id UUID,
  
  -- Solde avant/après
  balance_before INTEGER NOT NULL,
  balance_after INTEGER NOT NULL,
  
  -- Métadonnées
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index
CREATE INDEX idx_wallet_transactions_wallet_id ON wallet_transactions(wallet_id);
CREATE INDEX idx_wallet_transactions_type ON wallet_transactions(type);
CREATE INDEX idx_wallet_transactions_created_at ON wallet_transactions(created_at DESC);

-- =====================================================
-- RETRAITS (WITHDRAWALS)
-- =====================================================

CREATE TYPE withdrawal_status AS ENUM (
  'PENDING',
  'PROCESSING',
  'COMPLETED',
  'FAILED',
  'CANCELED'
);

CREATE TABLE IF NOT EXISTS withdrawals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Wallet et utilisateur
  wallet_id UUID NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  
  -- Montant
  amount INTEGER NOT NULL CHECK (amount > 0),
  currency TEXT DEFAULT 'GNF',
  
  -- Statut
  status withdrawal_status DEFAULT 'PENDING',
  
  -- Destination
  destination_type TEXT NOT NULL, -- bank_account, mobile_money, stripe_payout
  destination_details JSONB NOT NULL,
  
  -- Références externes
  stripe_payout_id TEXT,
  external_reference TEXT,
  
  -- Frais
  fee_amount INTEGER DEFAULT 0,
  net_amount INTEGER NOT NULL,
  
  -- Dates
  requested_at TIMESTAMPTZ DEFAULT NOW(),
  processed_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  
  -- Erreurs
  error_message TEXT,
  
  -- Approbation (si montant élevé)
  requires_approval BOOLEAN DEFAULT false,
  approved_by UUID REFERENCES profiles(id),
  approved_at TIMESTAMPTZ,
  
  -- Métadonnées
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index
CREATE INDEX idx_withdrawals_wallet_id ON withdrawals(wallet_id);
CREATE INDEX idx_withdrawals_user_id ON withdrawals(user_id);
CREATE INDEX idx_withdrawals_status ON withdrawals(status);

-- =====================================================
-- ROW LEVEL SECURITY (RLS)
-- =====================================================

-- stripe_transactions
ALTER TABLE stripe_transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own transactions"
  ON stripe_transactions FOR SELECT
  USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

CREATE POLICY "Admins can view all transactions"
  ON stripe_transactions FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
      AND profiles.role IN ('CEO', 'SUPER_ADMIN', 'ADMIN')
    )
  );

-- wallets
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own wallet"
  ON wallets FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can update own wallet balance (via functions only)"
  ON wallets FOR UPDATE
  USING (false); -- Uniquement via functions sécurisées

CREATE POLICY "Admins can view all wallets"
  ON wallets FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
      AND profiles.role IN ('CEO', 'SUPER_ADMIN', 'ADMIN')
    )
  );

-- wallet_transactions
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own wallet transactions"
  ON wallet_transactions FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM wallets
      WHERE wallets.id = wallet_transactions.wallet_id
      AND wallets.user_id = auth.uid()
    )
  );

-- withdrawals
ALTER TABLE withdrawals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own withdrawals"
  ON withdrawals FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can request withdrawals"
  ON withdrawals FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- =====================================================
-- FONCTIONS
-- =====================================================

-- Fonction: Créer/Récupérer wallet
CREATE OR REPLACE FUNCTION get_or_create_wallet(p_user_id UUID)
RETURNS UUID AS $$
DECLARE
  v_wallet_id UUID;
BEGIN
  -- Essayer de récupérer wallet existant
  SELECT id INTO v_wallet_id
  FROM wallets
  WHERE user_id = p_user_id;
  
  -- Si n'existe pas, créer
  IF v_wallet_id IS NULL THEN
    INSERT INTO wallets (user_id, available_balance, currency)
    VALUES (p_user_id, 0, 'GNF')
    RETURNING id INTO v_wallet_id;
  END IF;
  
  RETURN v_wallet_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction: Mettre à jour wallet après paiement réussi
CREATE OR REPLACE FUNCTION process_successful_payment(
  p_transaction_id UUID
)
RETURNS BOOLEAN AS $$
DECLARE
  v_transaction stripe_transactions;
  v_seller_wallet_id UUID;
  v_platform_wallet_id UUID;
  v_platform_user_id UUID;
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
  
  -- Récupérer CEO/Platform wallet (supposons role='CEO')
  SELECT id INTO v_platform_user_id
  FROM profiles
  WHERE role = 'CEO'
  LIMIT 1;
  
  IF v_platform_user_id IS NOT NULL THEN
    v_platform_wallet_id := get_or_create_wallet(v_platform_user_id);
  END IF;
  
  -- Mettre à jour solde vendeur (montant net)
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
  )
  SELECT
    v_seller_wallet_id,
    'PAYMENT',
    v_transaction.seller_net_amount,
    v_transaction.currency,
    'Payment received from order ' || COALESCE(v_transaction.order_id::TEXT, 'N/A'),
    v_transaction.id,
    v_transaction.order_id,
    w.available_balance - v_transaction.seller_net_amount,
    w.available_balance
  FROM wallets w
  WHERE w.id = v_seller_wallet_id;
  
  -- Mettre à jour wallet plateforme (commission)
  IF v_platform_wallet_id IS NOT NULL THEN
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
    )
    SELECT
      v_platform_wallet_id,
      'COMMISSION',
      v_transaction.commission_amount,
      v_transaction.currency,
      'Platform commission from order ' || COALESCE(v_transaction.order_id::TEXT, 'N/A'),
      v_transaction.id,
      w.available_balance - v_transaction.commission_amount,
      w.available_balance
    FROM wallets w
    WHERE w.id = v_platform_wallet_id;
  END IF;
  
  -- ✅ NOUVEAU: Calculer et créditer commission agent
  DECLARE
    v_buyer_creator_agent_id UUID;
    v_buyer_creator_type VARCHAR(20);
    v_agent_commission_amount DECIMAL(15,2);
    v_agent_commission_rate DECIMAL(5,4);
    v_agent_wallet_id UUID;
  BEGIN
    -- 1. Identifier agent créateur du client acheteur
    SELECT creator_id, creator_type 
    INTO v_buyer_creator_agent_id, v_buyer_creator_type
    FROM agent_created_users
    WHERE user_id = v_transaction.buyer_id;
    
    IF v_buyer_creator_agent_id IS NOT NULL THEN
      -- 2. Récupérer taux commission agent depuis config
      SELECT setting_value INTO v_agent_commission_rate
      FROM commission_settings
      WHERE setting_key = 'base_user_commission';
      
      -- Par défaut 20% si non trouvé
      IF v_agent_commission_rate IS NULL THEN
        v_agent_commission_rate := 0.20;
      END IF;
      
      -- 3. Calculer commission agent (% du montant net vendeur)
      v_agent_commission_amount := v_transaction.seller_net_amount * v_agent_commission_rate;
      
      -- 4. Créer/récupérer wallet agent
      v_agent_wallet_id := get_or_create_wallet(v_buyer_creator_agent_id);
      
      -- 5. Créditer wallet agent
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
      )
      SELECT
        v_agent_wallet_id,
        'AGENT_COMMISSION',
        v_agent_commission_amount,
        v_transaction.currency,
        'Commission agent - Achat client (ordre: ' || COALESCE(v_transaction.order_id::TEXT, 'N/A') || ')',
        v_transaction.id,
        w.available_balance - v_agent_commission_amount,
        w.available_balance
      FROM wallets w
      WHERE w.id = v_agent_wallet_id;
      
      RAISE NOTICE '✅ Commission agent créditée: % GNF pour agent %', v_agent_commission_amount, v_buyer_creator_agent_id;
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      -- Logger l'erreur mais ne pas bloquer le paiement principal
      RAISE WARNING '⚠️ Erreur calcul commission agent: %', SQLERRM;
  END;
  
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction: Geler montant pour litige
CREATE OR REPLACE FUNCTION freeze_amount(
  p_wallet_id UUID,
  p_amount INTEGER
)
RETURNS BOOLEAN AS $$
BEGIN
  UPDATE wallets
  SET
    available_balance = available_balance - p_amount,
    frozen_balance = frozen_balance + p_amount,
    updated_at = NOW()
  WHERE id = p_wallet_id
  AND available_balance >= p_amount;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient balance to freeze';
  END IF;
  
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction: Débloquer montant gelé
CREATE OR REPLACE FUNCTION unfreeze_amount(
  p_wallet_id UUID,
  p_amount INTEGER
)
RETURNS BOOLEAN AS $$
BEGIN
  UPDATE wallets
  SET
    available_balance = available_balance + p_amount,
    frozen_balance = frozen_balance - p_amount,
    updated_at = NOW()
  WHERE id = p_wallet_id
  AND frozen_balance >= p_amount;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Insufficient frozen balance to unfreeze';
  END IF;
  
  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- TRIGGERS
-- =====================================================

-- Trigger: updated_at auto-update
CREATE TRIGGER update_stripe_config_updated_at
  BEFORE UPDATE ON stripe_config
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_stripe_transactions_updated_at
  BEFORE UPDATE ON stripe_transactions
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_wallets_updated_at
  BEFORE UPDATE ON wallets
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_withdrawals_updated_at
  BEFORE UPDATE ON withdrawals
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- =====================================================
-- VUES
-- =====================================================

-- Vue: Statistiques wallet utilisateur
CREATE OR REPLACE VIEW user_wallet_stats AS
SELECT
  w.user_id,
  p.full_name,
  p.email,
  w.available_balance,
  w.pending_balance,
  w.frozen_balance,
  w.currency,
  w.total_earned,
  w.total_withdrawn,
  w.total_transactions,
  w.status AS wallet_status,
  w.is_verified,
  COUNT(DISTINCT wt.id) AS transaction_count,
  COUNT(DISTINCT wd.id) FILTER (WHERE wd.status = 'COMPLETED') AS completed_withdrawals
FROM wallets w
INNER JOIN profiles p ON p.id = w.user_id
LEFT JOIN wallet_transactions wt ON wt.wallet_id = w.id
LEFT JOIN withdrawals wd ON wd.wallet_id = w.id
GROUP BY w.id, p.full_name, p.email;

-- Vue: Transactions récentes
CREATE OR REPLACE VIEW recent_transactions AS
SELECT
  st.id,
  st.stripe_payment_intent_id,
  st.amount,
  st.currency,
  st.status,
  st.commission_amount,
  st.seller_net_amount,
  bp.full_name AS buyer_name,
  bp.email AS buyer_email,
  sp.full_name AS seller_name,
  sp.email AS seller_email,
  st.payment_method,
  st.card_brand,
  st.last4,
  st.created_at,
  st.paid_at
FROM stripe_transactions st
INNER JOIN profiles bp ON bp.id = st.buyer_id
INNER JOIN profiles sp ON sp.id = st.seller_id
ORDER BY st.created_at DESC;

-- Permissions vues
GRANT SELECT ON user_wallet_stats TO authenticated;
GRANT SELECT ON recent_transactions TO authenticated;

-- =====================================================
-- DONNÉES INITIALES
-- =====================================================

-- Insérer configuration par défaut
INSERT INTO stripe_config (
  platform_commission_rate,
  default_currency,
  supported_currencies,
  require_3d_secure,
  enable_subscriptions
)
VALUES (
  10.00, -- 10% commission
  'GNF',
  '["GNF", "USD", "EUR"]'::jsonb,
  true,
  false
)
ON CONFLICT DO NOTHING;

-- Créer wallet pour CEO (plateforme)
INSERT INTO wallets (user_id, available_balance, currency, is_verified, verification_level)
SELECT
  id,
  0,
  'GNF',
  true,
  'advanced'
FROM profiles
WHERE role = 'CEO'
LIMIT 1
ON CONFLICT (user_id) DO NOTHING;

-- =====================================================
-- COMMENTAIRES
-- =====================================================

COMMENT ON TABLE stripe_config IS 'Configuration globale Stripe et commission plateforme';
COMMENT ON TABLE stripe_transactions IS 'Transactions Stripe avec détails paiement et commission';
COMMENT ON TABLE wallets IS 'Wallet interne utilisateur avec soldes disponible/pending/frozen';
COMMENT ON TABLE wallet_transactions IS 'Historique complet des mouvements wallet';
COMMENT ON TABLE withdrawals IS 'Demandes de retrait vers banque/mobile money';
COMMENT ON FUNCTION process_successful_payment IS 'Traite un paiement réussi et met à jour les wallets';
COMMENT ON FUNCTION freeze_amount IS 'Gèle un montant wallet pour litige';
