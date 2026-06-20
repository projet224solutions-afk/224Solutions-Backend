-- ============================================
-- 🔐 SECURITY HARDENING MIGRATION
-- Fixes critical security issues identified
-- ============================================

-- 1. Create webhook audit tables
CREATE TABLE IF NOT EXISTS webhook_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type TEXT NOT NULL,
  payment_id TEXT,
  status TEXT NOT NULL,
  details TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS webhook_processed_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id TEXT NOT NULL,
  processed_at TEXT NOT NULL,
  event_type TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(payment_id, processed_at)
);

-- 2. Create auth attempts log table
CREATE TABLE IF NOT EXISTS auth_attempts_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  identifier TEXT NOT NULL,
  role TEXT,
  success BOOLEAN DEFAULT false,
  ip_address TEXT,
  user_agent TEXT,
  attempted_at TIMESTAMPTZ DEFAULT now()
);

-- 3. Create wallet idempotency table
CREATE TABLE IF NOT EXISTS wallet_idempotency_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key TEXT UNIQUE NOT NULL,
  user_id UUID NOT NULL,
  operation TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ
);

-- Enable RLS on new tables
ALTER TABLE webhook_audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_processed_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth_attempts_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_idempotency_keys ENABLE ROW LEVEL SECURITY;

-- RLS for new tables (admin only)
CREATE POLICY "admin_only_webhook_audit" ON webhook_audit_logs FOR ALL USING (
  EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

CREATE POLICY "admin_only_webhook_events" ON webhook_processed_events FOR ALL USING (
  EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

CREATE POLICY "admin_only_auth_attempts" ON auth_attempts_log FOR ALL USING (
  EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

CREATE POLICY "user_own_idempotency" ON wallet_idempotency_keys FOR ALL USING (
  auth.uid() = user_id
);

-- 4. Fix sos_alerts RLS policies (remove public access)
DROP POLICY IF EXISTS "Bureaux can view their SOS alerts" ON sos_alerts;
DROP POLICY IF EXISTS "Bureaux can update their SOS alerts" ON sos_alerts;

CREATE POLICY "Bureaux can view own SOS alerts secure" ON sos_alerts
FOR SELECT USING (
  auth.uid() IS NOT NULL AND (
    bureau_id IN (SELECT id FROM bureaus WHERE president_email = (SELECT email FROM auth.users WHERE id = auth.uid()))
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  )
);

CREATE POLICY "Bureaux can update own SOS alerts secure" ON sos_alerts
FOR UPDATE USING (
  auth.uid() IS NOT NULL AND (
    bureau_id IN (SELECT id FROM bureaus WHERE president_email = (SELECT email FROM auth.users WHERE id = auth.uid()))
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  )
);

-- 5. Fix vendor_agents RLS policies (remove anon access)
DROP POLICY IF EXISTS "agents_read_own_via_token" ON vendor_agents;

CREATE POLICY "vendor_agents_select_secure" ON vendor_agents
FOR SELECT TO authenticated
USING (
  vendor_id = auth.uid()
  OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
);

-- 6. Create atomic transfer function
CREATE OR REPLACE FUNCTION execute_atomic_wallet_transfer(
  p_sender_id UUID,
  p_receiver_id UUID,
  p_amount NUMERIC,
  p_description TEXT,
  p_sender_wallet_id UUID,
  p_recipient_wallet_id UUID,
  p_sender_balance_before NUMERIC,
  p_recipient_balance_before NUMERIC
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tx_id UUID;
  v_new_sender_balance NUMERIC;
  v_new_recipient_balance NUMERIC;
BEGIN
  v_new_sender_balance := p_sender_balance_before - p_amount;
  v_new_recipient_balance := p_recipient_balance_before + p_amount;
  v_tx_id := gen_random_uuid();
  
  -- Debit sender with optimistic lock
  UPDATE wallets SET balance = v_new_sender_balance, updated_at = now()
  WHERE id = p_sender_wallet_id AND balance = p_sender_balance_before;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Concurrent modification detected';
  END IF;
  
  -- Credit receiver
  UPDATE wallets SET balance = v_new_recipient_balance, updated_at = now()
  WHERE id = p_recipient_wallet_id;
  
  IF NOT FOUND THEN
    -- Rollback sender
    UPDATE wallets SET balance = p_sender_balance_before WHERE id = p_sender_wallet_id;
    RAISE EXCEPTION 'Recipient wallet not found';
  END IF;
  
  -- Record transaction
  INSERT INTO enhanced_transactions (id, sender_id, receiver_id, amount, method, status, currency, transaction_type, metadata)
  VALUES (v_tx_id, p_sender_id, p_receiver_id, p_amount, 'wallet', 'completed', 'GNF', 'transfer', 
          jsonb_build_object('description', p_description, 'atomic', true));
  
  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id);
END;
$$;

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_wallet_idempotency_expires ON wallet_idempotency_keys(expires_at);
CREATE INDEX IF NOT EXISTS idx_auth_attempts_identifier ON auth_attempts_log(identifier, attempted_at DESC);
CREATE INDEX IF NOT EXISTS idx_webhook_audit_payment ON webhook_audit_logs(payment_id, created_at DESC);