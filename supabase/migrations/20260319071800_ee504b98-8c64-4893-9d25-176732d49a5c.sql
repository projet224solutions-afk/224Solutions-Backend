
-- 1. Add pricing columns to digital_products
ALTER TABLE public.digital_products 
  ADD COLUMN IF NOT EXISTS pricing_type TEXT NOT NULL DEFAULT 'one_time',
  ADD COLUMN IF NOT EXISTS subscription_interval TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS access_duration TEXT DEFAULT 'lifetime';

-- Add check constraint for pricing_type
ALTER TABLE public.digital_products 
  ADD CONSTRAINT chk_pricing_type CHECK (pricing_type IN ('one_time', 'subscription', 'pay_what_you_want'));

-- 2. Create digital_subscriptions table for recurring billing
CREATE TABLE IF NOT EXISTS public.digital_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES public.digital_products(id) ON DELETE CASCADE,
  buyer_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  merchant_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'past_due', 'cancelled', 'expired', 'paused')),
  billing_cycle TEXT NOT NULL DEFAULT 'monthly' CHECK (billing_cycle IN ('monthly', 'yearly', 'lifetime')),
  amount_per_period NUMERIC NOT NULL,
  currency TEXT NOT NULL DEFAULT 'GNF',
  current_period_start TIMESTAMPTZ NOT NULL DEFAULT now(),
  current_period_end TIMESTAMPTZ NOT NULL,
  next_billing_date TIMESTAMPTZ,
  auto_renew BOOLEAN NOT NULL DEFAULT true,
  payment_method TEXT NOT NULL DEFAULT 'wallet',
  total_payments_made INTEGER NOT NULL DEFAULT 1,
  total_amount_paid NUMERIC NOT NULL DEFAULT 0,
  last_payment_at TIMESTAMPTZ DEFAULT now(),
  last_payment_transaction_id TEXT,
  failed_payment_count INTEGER NOT NULL DEFAULT 0,
  cancelled_at TIMESTAMPTZ,
  cancellation_reason TEXT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(product_id, buyer_id)
);

-- 3. RLS policies for digital_subscriptions
ALTER TABLE public.digital_subscriptions ENABLE ROW LEVEL SECURITY;

-- Buyers can read their own subscriptions
CREATE POLICY "buyers_read_own_subscriptions" ON public.digital_subscriptions
  FOR SELECT TO authenticated
  USING (buyer_id = auth.uid());

-- Merchants can read subscriptions for their products
CREATE POLICY "merchants_read_product_subscriptions" ON public.digital_subscriptions
  FOR SELECT TO authenticated
  USING (merchant_id = auth.uid());

-- Buyers can insert their own subscriptions
CREATE POLICY "buyers_create_subscriptions" ON public.digital_subscriptions
  FOR INSERT TO authenticated
  WITH CHECK (buyer_id = auth.uid());

-- Buyers can update their own subscriptions (cancel, etc.)
CREATE POLICY "buyers_update_own_subscriptions" ON public.digital_subscriptions
  FOR UPDATE TO authenticated
  USING (buyer_id = auth.uid());

-- Service role can do everything (for cron/edge functions)
CREATE POLICY "service_role_full_access" ON public.digital_subscriptions
  FOR ALL TO service_role
  USING (true)
  WITH CHECK (true);

-- 4. Index for efficient cron queries
CREATE INDEX IF NOT EXISTS idx_digital_subs_next_billing 
  ON public.digital_subscriptions(next_billing_date) 
  WHERE status = 'active' AND auto_renew = true;

CREATE INDEX IF NOT EXISTS idx_digital_subs_buyer 
  ON public.digital_subscriptions(buyer_id, status);

-- 5. Function to process subscription renewal
CREATE OR REPLACE FUNCTION public.process_digital_subscription_renewal(p_subscription_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sub RECORD;
  v_buyer_balance NUMERIC;
  v_new_period_end TIMESTAMPTZ;
  v_result JSONB;
BEGIN
  -- Lock the subscription row
  SELECT * INTO v_sub FROM digital_subscriptions WHERE id = p_subscription_id FOR UPDATE;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Subscription not found');
  END IF;
  
  IF v_sub.status != 'active' OR v_sub.auto_renew = false THEN
    RETURN jsonb_build_object('success', false, 'error', 'Subscription is not active or auto-renew is off');
  END IF;
  
  -- Check buyer wallet balance
  SELECT COALESCE(balance, 0) INTO v_buyer_balance FROM wallets WHERE user_id = v_sub.buyer_id;
  
  IF v_buyer_balance < v_sub.amount_per_period THEN
    -- Insufficient funds - mark as past_due
    UPDATE digital_subscriptions SET 
      status = 'past_due',
      failed_payment_count = failed_payment_count + 1,
      updated_at = now()
    WHERE id = p_subscription_id;
    
    RETURN jsonb_build_object('success', false, 'error', 'Insufficient funds', 'status', 'past_due');
  END IF;
  
  -- Calculate new period end
  IF v_sub.billing_cycle = 'monthly' THEN
    v_new_period_end := v_sub.current_period_end + INTERVAL '1 month';
  ELSIF v_sub.billing_cycle = 'yearly' THEN
    v_new_period_end := v_sub.current_period_end + INTERVAL '1 year';
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'Invalid billing cycle for renewal');
  END IF;
  
  -- Debit buyer wallet
  UPDATE wallets SET 
    balance = balance - v_sub.amount_per_period,
    updated_at = now()
  WHERE user_id = v_sub.buyer_id;
  
  -- Credit merchant wallet
  UPDATE wallets SET 
    balance = balance + v_sub.amount_per_period,
    updated_at = now()
  WHERE user_id = v_sub.merchant_id;
  
  -- Record wallet transactions
  INSERT INTO wallet_transactions (user_id, type, amount, description, metadata)
  VALUES (
    v_sub.buyer_id, 'payment', v_sub.amount_per_period,
    'Renouvellement abonnement numérique',
    jsonb_build_object('subscription_id', p_subscription_id, 'product_id', v_sub.product_id, 'period', v_sub.billing_cycle)
  );
  
  INSERT INTO wallet_transactions (user_id, type, amount, description, metadata)
  VALUES (
    v_sub.merchant_id, 'deposit', v_sub.amount_per_period,
    'Revenu abonnement numérique',
    jsonb_build_object('subscription_id', p_subscription_id, 'product_id', v_sub.product_id, 'buyer_id', v_sub.buyer_id)
  );
  
  -- Update subscription
  UPDATE digital_subscriptions SET
    current_period_start = current_period_end,
    current_period_end = v_new_period_end,
    next_billing_date = v_new_period_end,
    last_payment_at = now(),
    total_payments_made = total_payments_made + 1,
    total_amount_paid = total_amount_paid + v_sub.amount_per_period,
    failed_payment_count = 0,
    status = 'active',
    updated_at = now()
  WHERE id = p_subscription_id;
  
  -- Update access in digital_product_purchases
  UPDATE digital_product_purchases SET
    access_expires_at = v_new_period_end,
    access_granted = true,
    updated_at = now()
  WHERE product_id = v_sub.product_id AND buyer_id = v_sub.buyer_id;
  
  RETURN jsonb_build_object(
    'success', true, 
    'new_period_end', v_new_period_end,
    'amount_charged', v_sub.amount_per_period
  );
END;
$$;
