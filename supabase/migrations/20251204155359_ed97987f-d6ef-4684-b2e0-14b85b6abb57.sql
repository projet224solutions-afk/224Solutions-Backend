-- Drop all versions of the function first
DROP FUNCTION IF EXISTS public.record_subscription_payment(UUID, UUID, INTEGER, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.record_subscription_payment(UUID, UUID, NUMERIC, TEXT, UUID, TEXT);
DROP FUNCTION IF EXISTS public.record_subscription_payment(UUID, UUID, NUMERIC, TEXT, TEXT, TEXT);

-- Recreate with a single clean signature
CREATE OR REPLACE FUNCTION public.record_subscription_payment(
  p_user_id UUID,
  p_plan_id UUID,
  p_price_paid NUMERIC,
  p_payment_method TEXT DEFAULT 'wallet',
  p_payment_transaction_id TEXT DEFAULT NULL,
  p_billing_cycle TEXT DEFAULT 'monthly'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subscription_id UUID;
  v_period_end TIMESTAMP WITH TIME ZONE;
BEGIN
  -- Cancel all existing active subscriptions for this user
  UPDATE subscriptions 
  SET status = 'cancelled', updated_at = NOW()
  WHERE user_id = p_user_id AND status = 'active';

  -- Calculate period end based on billing cycle
  CASE p_billing_cycle
    WHEN 'yearly' THEN
      v_period_end := NOW() + INTERVAL '1 year';
    WHEN 'quarterly' THEN
      v_period_end := NOW() + INTERVAL '3 months';
    ELSE
      v_period_end := NOW() + INTERVAL '1 month';
  END CASE;

  -- Insert new subscription
  INSERT INTO subscriptions (
    user_id,
    plan_id,
    status,
    price_paid_gnf,
    billing_cycle,
    payment_method,
    payment_transaction_id,
    current_period_start,
    current_period_end,
    auto_renew,
    metadata,
    created_at,
    updated_at
  ) VALUES (
    p_user_id,
    p_plan_id,
    'active',
    p_price_paid::INTEGER,
    p_billing_cycle,
    p_payment_method,
    p_payment_transaction_id,
    NOW(),
    v_period_end,
    true,
    '{}'::jsonb,
    NOW(),
    NOW()
  )
  RETURNING id INTO v_subscription_id;

  -- Record revenue for PDG
  INSERT INTO revenus_pdg (
    source_type,
    source_id,
    amount,
    description,
    created_at
  ) VALUES (
    'subscription',
    v_subscription_id,
    p_price_paid,
    'Abonnement ' || p_billing_cycle || ' - Plan ID: ' || p_plan_id::text,
    NOW()
  );

  RETURN v_subscription_id;
END;
$$;