-- STRIPE PAYMENT SYSTEM v3.0
-- 224SOLUTIONS - Migration sans conflits

-- Supprimer les types s'ils existent deja (en cas de re-run)
DROP TYPE IF EXISTS stripe_payment_status CASCADE;
DROP TYPE IF EXISTS stripe_transaction_type CASCADE;
DROP TYPE IF EXISTS stripe_wallet_status CASCADE;
DROP TYPE IF EXISTS stripe_withdrawal_status CASCADE;

-- Creer les types ENUM
CREATE TYPE stripe_payment_status AS ENUM ('PENDING', 'PROCESSING', 'SUCCEEDED', 'FAILED', 'CANCELED', 'REFUNDED', 'DISPUTED');
CREATE TYPE stripe_transaction_type AS ENUM ('PAYMENT', 'COMMISSION', 'WITHDRAWAL', 'REFUND', 'CHARGEBACK');
CREATE TYPE stripe_wallet_status AS ENUM ('ACTIVE', 'FROZEN', 'SUSPENDED');
CREATE TYPE stripe_withdrawal_status AS ENUM ('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED', 'CANCELED');

-- Table: stripe_config
CREATE TABLE IF NOT EXISTS stripe_config (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  platform_commission_rate DECIMAL(5,2) DEFAULT 10.00 CHECK (platform_commission_rate >= 0 AND platform_commission_rate <= 100),
  stripe_publishable_key TEXT,
  stripe_secret_key TEXT,
  stripe_webhook_secret TEXT,
  default_currency TEXT DEFAULT 'GNF',
  supported_currencies JSONB DEFAULT '["GNF", "USD", "EUR"]'::jsonb,
  require_3d_secure BOOLEAN DEFAULT true,
  enable_subscriptions BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_stripe_config_singleton ON stripe_config ((true));

-- Table: stripe_transactions
CREATE TABLE IF NOT EXISTS stripe_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_payment_intent_id TEXT UNIQUE,
  stripe_charge_id TEXT,
  buyer_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  seller_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  amount INTEGER NOT NULL CHECK (amount > 0),
  currency TEXT DEFAULT 'GNF',
  commission_rate DECIMAL(5,2) NOT NULL,
  commission_amount INTEGER NOT NULL CHECK (commission_amount >= 0),
  seller_net_amount INTEGER NOT NULL CHECK (seller_net_amount >= 0),
  status stripe_payment_status DEFAULT 'PENDING',
  order_id UUID,
  service_id UUID,
  product_id UUID,
  metadata JSONB DEFAULT '{}'::jsonb,
  payment_method TEXT,
  last4 TEXT,
  card_brand TEXT,
  requires_3ds BOOLEAN DEFAULT false,
  three_ds_status TEXT,
  error_code TEXT,
  error_message TEXT,
  paid_at TIMESTAMPTZ,
  refunded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stripe_transactions_buyer_id ON stripe_transactions(buyer_id);
CREATE INDEX IF NOT EXISTS idx_stripe_transactions_seller_id ON stripe_transactions(seller_id);
CREATE INDEX IF NOT EXISTS idx_stripe_transactions_status ON stripe_transactions(status);
CREATE INDEX IF NOT EXISTS idx_stripe_transactions_payment_intent ON stripe_transactions(stripe_payment_intent_id);
CREATE INDEX IF NOT EXISTS idx_stripe_transactions_order_id ON stripe_transactions(order_id);
CREATE INDEX IF NOT EXISTS idx_stripe_trans_created_at ON stripe_transactions(created_at DESC);

-- Table: stripe_wallets
CREATE TABLE IF NOT EXISTS stripe_wallets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE REFERENCES profiles(id) ON DELETE CASCADE,
  available_balance INTEGER DEFAULT 0 CHECK (available_balance >= 0),
  pending_balance INTEGER DEFAULT 0 CHECK (pending_balance >= 0),
  frozen_balance INTEGER DEFAULT 0 CHECK (frozen_balance >= 0),
  currency TEXT DEFAULT 'GNF',
  status stripe_wallet_status DEFAULT 'ACTIVE',
  total_earned INTEGER DEFAULT 0,
  total_withdrawn INTEGER DEFAULT 0,
  total_transactions INTEGER DEFAULT 0,
  is_verified BOOLEAN DEFAULT false,
  verification_level TEXT,
  daily_withdrawal_limit INTEGER,
  monthly_withdrawal_limit INTEGER,
  bank_account_id TEXT,
  payout_enabled BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  last_transaction_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_stripe_wallets_user_id ON stripe_wallets(user_id);
CREATE INDEX IF NOT EXISTS idx_stripe_wallets_status ON stripe_wallets(status);
CREATE INDEX IF NOT EXISTS idx_stripe_wallets_updated_at ON stripe_wallets(updated_at DESC);

-- Table: stripe_wallet_transactions
CREATE TABLE IF NOT EXISTS stripe_wallet_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_wallet_id UUID NOT NULL REFERENCES stripe_wallets(id) ON DELETE CASCADE,
  transaction_type stripe_transaction_type NOT NULL,
  amount INTEGER NOT NULL CHECK (amount > 0),
  currency TEXT DEFAULT 'GNF',
  balance_before INTEGER NOT NULL,
  balance_after INTEGER NOT NULL,
  reference_type TEXT,
  reference_id UUID,
  stripe_payment_intent_id TEXT,
  description TEXT,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stripe_wallet_trans_wallet_id ON stripe_wallet_transactions(stripe_wallet_id);
CREATE INDEX IF NOT EXISTS idx_stripe_wallet_trans_type ON stripe_wallet_transactions(transaction_type);
CREATE INDEX IF NOT EXISTS idx_stripe_wallet_trans_created ON stripe_wallet_transactions(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_stripe_wallet_trans_ref ON stripe_wallet_transactions(reference_id);

-- Table: stripe_withdrawals
CREATE TABLE IF NOT EXISTS stripe_withdrawals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_wallet_id UUID NOT NULL REFERENCES stripe_wallets(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  amount INTEGER NOT NULL CHECK (amount > 0),
  currency TEXT DEFAULT 'GNF',
  fee INTEGER DEFAULT 0 CHECK (fee >= 0),
  net_amount INTEGER NOT NULL CHECK (net_amount > 0),
  status stripe_withdrawal_status DEFAULT 'PENDING',
  bank_account_name TEXT,
  bank_account_number TEXT,
  bank_name TEXT,
  bank_code TEXT,
  stripe_payout_id TEXT UNIQUE,
  requested_at TIMESTAMPTZ DEFAULT NOW(),
  processed_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  failure_reason TEXT,
  failure_code TEXT,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_wallet_id ON stripe_withdrawals(stripe_wallet_id);
CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_user_id ON stripe_withdrawals(user_id);
CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_status ON stripe_withdrawals(status);
CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_requested ON stripe_withdrawals(requested_at DESC);

-- Fonction: Creer wallet Stripe automatique
CREATE OR REPLACE FUNCTION create_stripe_wallet_for_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO stripe_wallets (user_id, available_balance, pending_balance, frozen_balance, currency, status)
  VALUES (NEW.id, 0, 0, 0, 'GNF', 'ACTIVE')
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger: Creer wallet Stripe
DROP TRIGGER IF EXISTS trigger_create_stripe_wallet ON profiles;
CREATE TRIGGER trigger_create_stripe_wallet
  AFTER INSERT ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION create_stripe_wallet_for_user();

-- Fonction: Mettre a jour solde wallet Stripe
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
  SELECT available_balance INTO v_current_balance
  FROM stripe_wallets
  WHERE id = p_wallet_id
  FOR UPDATE;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Stripe wallet not found';
  END IF;
  
  IF p_transaction_type IN ('PAYMENT', 'REFUND') THEN
    v_new_balance := v_current_balance + p_amount;
  ELSIF p_transaction_type IN ('COMMISSION', 'WITHDRAWAL', 'CHARGEBACK') THEN
    v_new_balance := v_current_balance - p_amount;
    IF v_new_balance < 0 THEN
      RAISE EXCEPTION 'Insufficient balance';
    END IF;
  ELSE
    RAISE EXCEPTION 'Invalid transaction type';
  END IF;
  
  UPDATE stripe_wallets
  SET available_balance = v_new_balance, updated_at = NOW(), last_transaction_at = NOW()
  WHERE id = p_wallet_id;
  
  INSERT INTO stripe_wallet_transactions (stripe_wallet_id, transaction_type, amount, balance_before, balance_after, reference_id, description)
  VALUES (p_wallet_id, p_transaction_type, p_amount, v_current_balance, v_new_balance, p_reference_id, p_description);
  
  RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RLS Policies
ALTER TABLE stripe_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe_wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe_withdrawals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Configuration Stripe publique" ON stripe_config;
CREATE POLICY "Configuration Stripe publique" ON stripe_config FOR SELECT USING (true);

DROP POLICY IF EXISTS "Voir ses transactions Stripe" ON stripe_transactions;
CREATE POLICY "Voir ses transactions Stripe" ON stripe_transactions FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

DROP POLICY IF EXISTS "Voir son wallet Stripe" ON stripe_wallets;
CREATE POLICY "Voir son wallet Stripe" ON stripe_wallets FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Voir ses transactions wallet Stripe" ON stripe_wallet_transactions;
CREATE POLICY "Voir ses transactions wallet Stripe" ON stripe_wallet_transactions FOR SELECT USING (EXISTS (SELECT 1 FROM stripe_wallets WHERE id = stripe_wallet_id AND user_id = auth.uid()));

DROP POLICY IF EXISTS "Voir ses retraits Stripe" ON stripe_withdrawals;
CREATE POLICY "Voir ses retraits Stripe" ON stripe_withdrawals FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Creer retrait Stripe" ON stripe_withdrawals;
CREATE POLICY "Creer retrait Stripe" ON stripe_withdrawals FOR INSERT WITH CHECK (auth.uid() = user_id);
