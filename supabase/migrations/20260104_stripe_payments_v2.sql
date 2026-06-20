-- =====================================================
-- STRIPE PAYMENT SYSTEM v2.0 - SANS CONFLITS
-- Système de paiement Stripe avec wallets dédiés
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
-- TYPES ENUM STRIPE (avec préfixe stripe_)
-- =====================================================

-- Statut des paiements Stripe
CREATE TYPE stripe_payment_status AS ENUM (
  'PENDING',
  'PROCESSING',
  'SUCCEEDED',
  'FAILED',
  'CANCELED',
  'REFUNDED',
  'DISPUTED'
);

-- Type de transaction Stripe
CREATE TYPE stripe_transaction_type AS ENUM (
  'PAYMENT',
  'COMMISSION',
  'WITHDRAWAL',
  'REFUND',
  'CHARGEBACK'
);

-- Statut du wallet Stripe
CREATE TYPE stripe_wallet_status AS ENUM (
  'ACTIVE',
  'FROZEN',
  'SUSPENDED'
);

-- Statut des retraits
CREATE TYPE stripe_withdrawal_status AS ENUM (
  'PENDING',
  'PROCESSING',
  'COMPLETED',
  'FAILED',
  'CANCELED'
);

-- =====================================================
-- TRANSACTIONS STRIPE
-- =====================================================

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
  status stripe_payment_status DEFAULT 'PENDING',
  
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
-- STRIPE WALLETS (séparés des wallets existants)
-- =====================================================

CREATE TABLE IF NOT EXISTS stripe_wallets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Propriétaire du wallet Stripe
  user_id UUID NOT NULL UNIQUE REFERENCES profiles(id) ON DELETE CASCADE,
  
  -- Soldes Stripe (en centimes/unités minimales)
  available_balance INTEGER DEFAULT 0 CHECK (available_balance >= 0),
  pending_balance INTEGER DEFAULT 0 CHECK (pending_balance >= 0),
  frozen_balance INTEGER DEFAULT 0 CHECK (frozen_balance >= 0),
  
  -- Devise
  currency TEXT DEFAULT 'GNF',
  
  -- Statut
  status stripe_wallet_status DEFAULT 'ACTIVE',
  
  -- Métadonnées Stripe
  total_earned INTEGER DEFAULT 0,
  total_withdrawn INTEGER DEFAULT 0,
  total_transactions INTEGER DEFAULT 0,
  
  -- KYC / Vérification (pour retraits Stripe)
  is_verified BOOLEAN DEFAULT false,
  verification_level TEXT, -- basic, intermediate, advanced
  
  -- Limites de retrait
  daily_withdrawal_limit INTEGER, -- NULL = pas de limite
  monthly_withdrawal_limit INTEGER,
  
  -- Informations bancaires pour retraits
  bank_account_id TEXT, -- ID compte Stripe Connect
  payout_enabled BOOLEAN DEFAULT false,
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  last_transaction_at TIMESTAMPTZ
);

-- Index
CREATE INDEX idx_stripe_wallets_user_id ON stripe_wallets(user_id);
CREATE INDEX idx_stripe_wallets_status ON stripe_wallets(status);

-- =====================================================
-- TRANSACTIONS WALLET STRIPE (historique)
-- =====================================================

CREATE TABLE IF NOT EXISTS stripe_wallet_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Wallet Stripe concerné
  stripe_wallet_id UUID NOT NULL REFERENCES stripe_wallets(id) ON DELETE CASCADE,
  
  -- Type de transaction
  transaction_type stripe_transaction_type NOT NULL,
  
  -- Montant (en centimes)
  amount INTEGER NOT NULL CHECK (amount > 0),
  currency TEXT DEFAULT 'GNF',
  
  -- Soldes avant/après
  balance_before INTEGER NOT NULL,
  balance_after INTEGER NOT NULL,
  
  -- Référence
  reference_type TEXT, -- 'payment', 'withdrawal', 'refund', etc.
  reference_id UUID, -- ID de la transaction/retrait associé
  stripe_payment_intent_id TEXT,
  
  -- Description
  description TEXT,
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index
CREATE INDEX idx_stripe_wallet_trans_wallet_id ON stripe_wallet_transactions(stripe_wallet_id);
CREATE INDEX idx_stripe_wallet_trans_type ON stripe_wallet_transactions(transaction_type);
CREATE INDEX idx_stripe_wallet_trans_created ON stripe_wallet_transactions(created_at DESC);

-- =====================================================
-- RETRAITS STRIPE
-- =====================================================

CREATE TABLE IF NOT EXISTS stripe_withdrawals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Wallet source
  stripe_wallet_id UUID NOT NULL REFERENCES stripe_wallets(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  
  -- Montant demandé (en centimes)
  amount INTEGER NOT NULL CHECK (amount > 0),
  currency TEXT DEFAULT 'GNF',
  
  -- Frais de retrait
  fee INTEGER DEFAULT 0 CHECK (fee >= 0),
  net_amount INTEGER NOT NULL CHECK (net_amount > 0),
  
  -- Statut
  status stripe_withdrawal_status DEFAULT 'PENDING',
  
  -- Informations bancaires
  bank_account_name TEXT,
  bank_account_number TEXT,
  bank_name TEXT,
  bank_code TEXT,
  
  -- Stripe Payout ID
  stripe_payout_id TEXT UNIQUE,
  
  -- Traitement
  requested_at TIMESTAMPTZ DEFAULT NOW(),
  processed_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  
  -- Erreurs
  failure_reason TEXT,
  failure_code TEXT,
  
  -- Métadonnées
  metadata JSONB DEFAULT '{}'::jsonb,
  
  -- Audit
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index
CREATE INDEX idx_stripe_withdrawals_wallet_id ON stripe_withdrawals(stripe_wallet_id);
CREATE INDEX idx_stripe_withdrawals_user_id ON stripe_withdrawals(user_id);
CREATE INDEX idx_stripe_withdrawals_status ON stripe_withdrawals(status);
CREATE INDEX idx_stripe_withdrawals_requested ON stripe_withdrawals(requested_at DESC);

-- =====================================================
-- FONCTIONS UTILITAIRES STRIPE
-- =====================================================

-- Fonction: Créer un wallet Stripe automatiquement
CREATE OR REPLACE FUNCTION create_stripe_wallet_for_user()
RETURNS TRIGGER AS $$
BEGIN
  -- Créer un wallet Stripe pour chaque nouvel utilisateur
  INSERT INTO stripe_wallets (
    user_id,
    available_balance,
    pending_balance,
    frozen_balance,
    currency,
    status
  ) VALUES (
    NEW.id,
    0,
    0,
    0,
    'GNF',
    'ACTIVE'
  )
  ON CONFLICT (user_id) DO NOTHING;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger: Créer wallet Stripe lors de la création d'un profil
DROP TRIGGER IF EXISTS trigger_create_stripe_wallet ON profiles;
CREATE TRIGGER trigger_create_stripe_wallet
  AFTER INSERT ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION create_stripe_wallet_for_user();

-- Fonction: Mettre à jour le solde du wallet Stripe
CREATE OR REPLACE FUNCTION update_stripe_wallet_balance(
  p_wallet_id UUID,
  p_amount INTEGER,
  p_transaction_type stripe_transaction_type,
  p_reference_id UUID DEFAULT NULL,
  p_description TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
  v_current_balance INTEGER;
  v_new_balance INTEGER;
BEGIN
  -- Récupérer le solde actuel
  SELECT available_balance INTO v_current_balance
  FROM stripe_wallets
  WHERE id = p_wallet_id
  FOR UPDATE;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Stripe wallet not found: %', p_wallet_id;
  END IF;
  
  -- Calculer le nouveau solde
  IF p_transaction_type IN ('PAYMENT', 'REFUND') THEN
    v_new_balance := v_current_balance + p_amount;
  ELSIF p_transaction_type IN ('COMMISSION', 'WITHDRAWAL', 'CHARGEBACK') THEN
    v_new_balance := v_current_balance - p_amount;
    IF v_new_balance < 0 THEN
      RAISE EXCEPTION 'Insufficient balance in Stripe wallet';
    END IF;
  ELSE
    RAISE EXCEPTION 'Invalid transaction type: %', p_transaction_type;
  END IF;
  
  -- Mettre à jour le wallet
  UPDATE stripe_wallets
  SET 
    available_balance = v_new_balance,
    updated_at = NOW(),
    last_transaction_at = NOW()
  WHERE id = p_wallet_id;
  
  -- Enregistrer la transaction
  INSERT INTO stripe_wallet_transactions (
    stripe_wallet_id,
    transaction_type,
    amount,
    balance_before,
    balance_after,
    reference_id,
    description
  ) VALUES (
    p_wallet_id,
    p_transaction_type,
    p_amount,
    v_current_balance,
    v_new_balance,
    p_reference_id,
    p_description
  );
  
  RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- POLITIQUES RLS (Row Level Security)
-- =====================================================

-- Activer RLS
ALTER TABLE stripe_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe_wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe_withdrawals ENABLE ROW LEVEL SECURITY;

-- Politique: Configuration Stripe (lecture seule pour tous)
CREATE POLICY "Configuration Stripe publique" ON stripe_config
  FOR SELECT USING (true);

-- Politique: Transactions Stripe (utilisateurs voient leurs transactions)
CREATE POLICY "Voir ses transactions Stripe" ON stripe_transactions
  FOR SELECT USING (
    auth.uid() = buyer_id OR 
    auth.uid() = seller_id
  );

-- Politique: Wallets Stripe (utilisateurs voient leur wallet)
CREATE POLICY "Voir son wallet Stripe" ON stripe_wallets
  FOR SELECT USING (auth.uid() = user_id);

-- Politique: Transactions wallet Stripe
CREATE POLICY "Voir ses transactions wallet Stripe" ON stripe_wallet_transactions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM stripe_wallets
      WHERE id = stripe_wallet_id
      AND user_id = auth.uid()
    )
  );

-- Politique: Retraits Stripe
CREATE POLICY "Voir ses retraits Stripe" ON stripe_withdrawals
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Créer retrait Stripe" ON stripe_withdrawals
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- =====================================================
-- INDEXES ADDITIONNELS POUR PERFORMANCE
-- =====================================================

CREATE INDEX idx_stripe_trans_created_at ON stripe_transactions(created_at DESC);
CREATE INDEX idx_stripe_wallets_updated_at ON stripe_wallets(updated_at DESC);
CREATE INDEX idx_stripe_wallet_trans_ref ON stripe_wallet_transactions(reference_id);

-- =====================================================
-- COMMENTAIRES
-- =====================================================

COMMENT ON TABLE stripe_config IS 'Configuration globale du système de paiement Stripe';
COMMENT ON TABLE stripe_transactions IS 'Historique de toutes les transactions Stripe';
COMMENT ON TABLE stripe_wallets IS 'Wallets Stripe dédiés pour les paiements par carte';
COMMENT ON TABLE stripe_wallet_transactions IS 'Historique des mouvements dans les wallets Stripe';
COMMENT ON TABLE stripe_withdrawals IS 'Demandes de retrait depuis les wallets Stripe';

-- =====================================================
-- FIN DE LA MIGRATION
-- =====================================================
