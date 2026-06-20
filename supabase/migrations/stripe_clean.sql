DROP TYPE IF EXISTS stripe_payment_status CASCADE;
DROP TYPE IF EXISTS stripe_transaction_type CASCADE;
DROP TYPE IF EXISTS stripe_wallet_status CASCADE;
DROP TYPE IF EXISTS stripe_withdrawal_status CASCADE;

CREATE TYPE stripe_payment_status AS ENUM ('PENDING', 'PROCESSING', 'SUCCEEDED', 'FAILED', 'CANCELED', 'REFUNDED', 'DISPUTED');
CREATE TYPE stripe_transaction_type AS ENUM ('PAYMENT', 'COMMISSION', 'WITHDRAWAL', 'REFUND', 'CHARGEBACK');
CREATE TYPE stripe_wallet_status AS ENUM ('ACTIVE', 'FROZEN', 'SUSPENDED');
CREATE TYPE stripe_withdrawal_status AS ENUM ('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED', 'CANCELED');

CREATE TABLE IF NOT EXISTS stripe_config (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  platform_commission_rate DECIMAL(5,2) DEFAULT 10.00,
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

CREATE TABLE IF NOT EXISTS stripe_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_payment_intent_id TEXT UNIQUE,
  stripe_charge_id TEXT,
  buyer_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  seller_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  amount INTEGER NOT NULL,
  currency TEXT DEFAULT 'GNF',
  commission_rate DECIMAL(5,2) NOT NULL,
  commission_amount INTEGER NOT NULL,
  seller_net_amount INTEGER NOT NULL,
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

CREATE INDEX IF NOT EXISTS idx_stripe_transactions_buyer ON stripe_transactions(buyer_id);
CREATE INDEX IF NOT EXISTS idx_stripe_transactions_seller ON stripe_transactions(seller_id);
CREATE INDEX IF NOT EXISTS idx_stripe_transactions_status ON stripe_transactions(status);
CREATE INDEX IF NOT EXISTS idx_stripe_transactions_intent ON stripe_transactions(stripe_payment_intent_id);

CREATE TABLE IF NOT EXISTS stripe_wallets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE REFERENCES profiles(id) ON DELETE CASCADE,
  available_balance INTEGER DEFAULT 0,
  pending_balance INTEGER DEFAULT 0,
  frozen_balance INTEGER DEFAULT 0,
  currency TEXT DEFAULT 'GNF',
  status stripe_wallet_status DEFAULT 'ACTIVE',
  total_earned INTEGER DEFAULT 0,
  total_withdrawn INTEGER DEFAULT 0,
  is_verified BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stripe_wallets_user ON stripe_wallets(user_id);

CREATE TABLE IF NOT EXISTS stripe_wallet_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_wallet_id UUID NOT NULL REFERENCES stripe_wallets(id) ON DELETE CASCADE,
  transaction_type stripe_transaction_type NOT NULL,
  amount INTEGER NOT NULL,
  currency TEXT DEFAULT 'GNF',
  balance_before INTEGER NOT NULL,
  balance_after INTEGER NOT NULL,
  reference_id UUID,
  description TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stripe_wallet_trans_wallet ON stripe_wallet_transactions(stripe_wallet_id);

CREATE TABLE IF NOT EXISTS stripe_withdrawals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_wallet_id UUID NOT NULL REFERENCES stripe_wallets(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  amount INTEGER NOT NULL,
  currency TEXT DEFAULT 'GNF',
  fee INTEGER DEFAULT 0,
  net_amount INTEGER NOT NULL,
  status stripe_withdrawal_status DEFAULT 'PENDING',
  bank_account_name TEXT,
  bank_account_number TEXT,
  stripe_payout_id TEXT UNIQUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_wallet ON stripe_withdrawals(stripe_wallet_id);

CREATE OR REPLACE FUNCTION create_stripe_wallet_for_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO stripe_wallets (user_id, available_balance, pending_balance, frozen_balance, currency, status)
  VALUES (NEW.id, 0, 0, 0, 'GNF', 'ACTIVE')
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_create_stripe_wallet ON profiles;
CREATE TRIGGER trigger_create_stripe_wallet
  AFTER INSERT ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION create_stripe_wallet_for_user();

ALTER TABLE stripe_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe_wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE stripe_withdrawals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "stripe_config_public" ON stripe_config;
CREATE POLICY "stripe_config_public" ON stripe_config FOR SELECT USING (true);

DROP POLICY IF EXISTS "stripe_transactions_select" ON stripe_transactions;
CREATE POLICY "stripe_transactions_select" ON stripe_transactions FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

DROP POLICY IF EXISTS "stripe_wallets_select" ON stripe_wallets;
CREATE POLICY "stripe_wallets_select" ON stripe_wallets FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "stripe_wallet_transactions_select" ON stripe_wallet_transactions;
CREATE POLICY "stripe_wallet_transactions_select" ON stripe_wallet_transactions FOR SELECT USING (EXISTS (SELECT 1 FROM stripe_wallets WHERE id = stripe_wallet_id AND user_id = auth.uid()));

DROP POLICY IF EXISTS "stripe_withdrawals_select" ON stripe_withdrawals;
CREATE POLICY "stripe_withdrawals_select" ON stripe_withdrawals FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "stripe_withdrawals_insert" ON stripe_withdrawals;
CREATE POLICY "stripe_withdrawals_insert" ON stripe_withdrawals FOR INSERT WITH CHECK (auth.uid() = user_id);
