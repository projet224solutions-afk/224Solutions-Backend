-- Correction des fonctions SECURITY DEFINER sans SET search_path (partie 1/2)

-- 1. acquire_taxi_lock
CREATE OR REPLACE FUNCTION public.acquire_taxi_lock(p_resource_type text, p_resource_id uuid, p_locked_by text, p_ttl_seconds integer DEFAULT 30)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = 'public'
AS $function$
DECLARE lock_acquired BOOLEAN := FALSE;
BEGIN
  DELETE FROM public.taxi_locks WHERE expires_at < NOW();
  INSERT INTO public.taxi_locks (resource_type, resource_id, locked_by, expires_at)
  VALUES (p_resource_type, p_resource_id, p_locked_by, NOW() + (p_ttl_seconds || ' seconds')::INTERVAL)
  ON CONFLICT DO NOTHING RETURNING TRUE INTO lock_acquired;
  RETURN COALESCE(lock_acquired, FALSE);
END;
$function$;

-- 2. auto_release_escrows
CREATE OR REPLACE FUNCTION public.auto_release_escrows()
 RETURNS TABLE(escrow_id uuid, success boolean, message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = 'public'
AS $function$
DECLARE
  v_escrow RECORD;
  v_commission_percent NUMERIC;
BEGIN
  SELECT COALESCE(
    (SELECT setting_value::NUMERIC FROM public.system_settings WHERE setting_key = 'escrow_commission_percent'),
    2.0
  ) INTO v_commission_percent;
  
  FOR v_escrow IN
    SELECT id
    FROM public.escrow_transactions
    WHERE status = 'pending'
      AND auto_release_enabled = true
      AND available_to_release_at <= now()
    ORDER BY available_to_release_at ASC
    LIMIT 100
  LOOP
    BEGIN
      PERFORM release_escrow(v_escrow.id, v_commission_percent, NULL);
      PERFORM log_escrow_action(v_escrow.id, 'auto_released', NULL, 'Auto-released by system');
      
      escrow_id := v_escrow.id;
      success := true;
      message := 'Auto-released successfully';
      RETURN NEXT;
    EXCEPTION WHEN OTHERS THEN
      escrow_id := v_escrow.id;
      success := false;
      message := SQLERRM;
      RETURN NEXT;
    END;
  END LOOP;
END;
$function$;

-- 3. block_ip_address
CREATE OR REPLACE FUNCTION public.block_ip_address(p_ip_address text, p_reason text, p_duration_hours integer DEFAULT 24, p_auto_block boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = 'public'
AS $function$
DECLARE
  v_block_id UUID;
BEGIN
  INSERT INTO blocked_ips (
    ip_address, reason, blocked_by_system, expires_at
  )
  VALUES (
    p_ip_address::INET, p_reason, p_auto_block, 
    NOW() + (p_duration_hours || ' hours')::INTERVAL
  )
  ON CONFLICT (ip_address) DO UPDATE
  SET is_active = TRUE, expires_at = NOW() + (p_duration_hours || ' hours')::INTERVAL
  RETURNING id INTO v_block_id;

  INSERT INTO security_audit_logs (
    action, actor_type, target_type, target_id, ip_address, details
  )
  VALUES (
    'ip_blocked', 'system', 'blocked_ip', v_block_id::TEXT, p_ip_address,
    jsonb_build_object('reason', p_reason, 'expires_hours', p_duration_hours)
  );

  RETURN v_block_id;
END;
$function$;

-- 4. calculate_vendor_trust_score
CREATE OR REPLACE FUNCTION public.calculate_vendor_trust_score(p_vendor_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = 'public'
AS $function$
DECLARE
  v_score INTEGER := 50;
  v_total_sales INTEGER;
  v_successful_orders INTEGER;
  v_cancelled_orders INTEGER;
  v_disputes INTEGER;
  v_account_age_days INTEGER;
BEGIN
  SELECT 
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0)
  INTO v_total_sales, v_successful_orders, v_cancelled_orders
  FROM payment_links
  WHERE vendor_id = p_vendor_id;
  
  SELECT EXTRACT(DAY FROM NOW() - created_at)::INTEGER
  INTO v_account_age_days
  FROM profiles
  WHERE id = p_vendor_id;
  
  v_score := 50;
  v_score := v_score + LEAST(v_successful_orders * 2, 30);
  v_score := v_score - (v_cancelled_orders * 5);
  v_score := v_score + LEAST(v_account_age_days / 10, 10);
  v_score := GREATEST(0, LEAST(100, v_score));
  
  INSERT INTO vendor_trust_score (vendor_id, score, total_sales, successful_orders, cancelled_orders, account_age_days)
  VALUES (p_vendor_id, v_score, v_total_sales, v_successful_orders, v_cancelled_orders, v_account_age_days)
  ON CONFLICT (vendor_id) DO UPDATE
  SET score = v_score,
      total_sales = v_total_sales,
      successful_orders = v_successful_orders,
      cancelled_orders = v_cancelled_orders,
      account_age_days = v_account_age_days,
      updated_at = NOW();
  
  RETURN v_score;
END;
$function$;

-- 5. mark_messages_as_read
CREATE OR REPLACE FUNCTION public.mark_messages_as_read(p_conversation_id uuid, p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = 'public'
AS $function$
BEGIN
  UPDATE messages
  SET status = 'read'
  WHERE conversation_id = p_conversation_id
    AND receiver_id = p_user_id
    AND status != 'read';
END;
$function$;

-- 6. release_escrow (DROP puis CREATE)
DROP FUNCTION IF EXISTS public.release_escrow(uuid, numeric, uuid);

CREATE FUNCTION public.release_escrow(p_escrow_id uuid, p_commission_percent numeric, p_released_by uuid DEFAULT NULL)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = 'public'
AS $function$
DECLARE
  v_escrow RECORD;
  v_commission_amount NUMERIC;
  v_vendor_amount NUMERIC;
BEGIN
  SELECT * INTO v_escrow
  FROM escrow_transactions
  WHERE id = p_escrow_id
  FOR UPDATE;

  IF NOT FOUND OR v_escrow.status != 'pending' THEN
    RETURN FALSE;
  END IF;

  v_commission_amount := v_escrow.amount * (p_commission_percent / 100);
  v_vendor_amount := v_escrow.amount - v_commission_amount;

  UPDATE wallets
  SET balance = balance + v_vendor_amount
  WHERE user_id = v_escrow.vendor_id;

  UPDATE escrow_transactions
  SET 
    status = 'released',
    released_at = now(),
    released_by = COALESCE(p_released_by, v_escrow.customer_id),
    commission_amount = v_commission_amount
  WHERE id = p_escrow_id;

  INSERT INTO commissions (
    transaction_id,
    amount,
    rate,
    transaction_type
  ) VALUES (
    p_escrow_id,
    v_commission_amount,
    p_commission_percent,
    'escrow_release'
  );

  RETURN TRUE;
END;
$function$;