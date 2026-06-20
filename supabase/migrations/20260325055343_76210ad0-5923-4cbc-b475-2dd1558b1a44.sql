-- Performance indexes (without CONCURRENTLY for migration compatibility)

CREATE INDEX IF NOT EXISTS idx_wallet_tx_status ON wallet_transactions(status);
CREATE INDEX IF NOT EXISTS idx_wallet_tx_sender ON wallet_transactions(sender_wallet_id);
CREATE INDEX IF NOT EXISTS idx_wallet_tx_receiver ON wallet_transactions(receiver_wallet_id);
CREATE INDEX IF NOT EXISTS idx_wallet_tx_created ON wallet_transactions(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_orders_vendor_id ON orders(vendor_id);
CREATE INDEX IF NOT EXISTS idx_orders_vendor_status ON orders(vendor_id, status);
CREATE INDEX IF NOT EXISTS idx_orders_payment_status ON orders(vendor_id, payment_status);

CREATE INDEX IF NOT EXISTS idx_products_vendor_active ON products(vendor_id, is_active) WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_profiles_role ON profiles(role);
CREATE INDEX IF NOT EXISTS idx_profiles_role_status ON profiles(role, status);

CREATE INDEX IF NOT EXISTS idx_notifications_user_read ON notifications(user_id, read) WHERE read = false;

CREATE INDEX IF NOT EXISTS idx_agent_commissions_agent ON agent_commissions_log(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_commissions_agent_date ON agent_commissions_log(agent_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_agent_created_users_agent ON agent_created_users(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_created_users_agent_date ON agent_created_users(agent_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_wallets_user_currency ON wallets(user_id, currency);