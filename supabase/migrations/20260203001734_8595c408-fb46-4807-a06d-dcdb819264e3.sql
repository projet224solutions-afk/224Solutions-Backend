
-- =====================================================
-- SURVEILLANCE LOGIQUE GLOBALE - DÉTECTION COMPLÈTE
-- =====================================================

-- Supprimer les fonctions existantes
DROP FUNCTION IF EXISTS public.detect_stock_anomalies();
DROP FUNCTION IF EXISTS public.detect_wallet_balance_anomalies();
DROP FUNCTION IF EXISTS public.detect_order_anomalies();
DROP FUNCTION IF EXISTS public.detect_commission_anomalies();
DROP FUNCTION IF EXISTS public.detect_user_anomalies();
DROP FUNCTION IF EXISTS public.detect_ledger_anomalies();
DROP FUNCTION IF EXISTS public.run_global_anomaly_detection(TEXT[]);
DROP FUNCTION IF EXISTS public.get_system_health();

-- 1. FINANCE: Détection des incohérences de soldes
CREATE FUNCTION public.detect_wallet_balance_anomalies()
RETURNS TABLE(
  wallet_id UUID,
  wallet_type TEXT,
  owner_id UUID,
  stored_balance NUMERIC,
  calculated_balance NUMERIC,
  difference NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    uw.id as wallet_id,
    'user_wallet'::TEXT as wallet_type,
    uw.user_id as owner_id,
    COALESCE(uw.balance, 0) as stored_balance,
    COALESCE((
      SELECT SUM(CASE WHEN wt.type IN ('credit', 'deposit', 'refund', 'commission') THEN wt.amount ELSE -wt.amount END)
      FROM wallet_transactions wt 
      WHERE wt.wallet_id = uw.id AND wt.status = 'completed'
    ), 0) as calculated_balance,
    COALESCE(uw.balance, 0) - COALESCE((
      SELECT SUM(CASE WHEN wt.type IN ('credit', 'deposit', 'refund', 'commission') THEN wt.amount ELSE -wt.amount END)
      FROM wallet_transactions wt 
      WHERE wt.wallet_id = uw.id AND wt.status = 'completed'
    ), 0) as difference
  FROM user_wallets uw
  WHERE ABS(COALESCE(uw.balance, 0) - COALESCE((
    SELECT SUM(CASE WHEN wt.type IN ('credit', 'deposit', 'refund', 'commission') THEN wt.amount ELSE -wt.amount END)
    FROM wallet_transactions wt 
    WHERE wt.wallet_id = uw.id AND wt.status = 'completed'
  ), 0)) > 0.01;
END;
$$;

-- 2. STOCK: Détection des stocks négatifs ou incohérents
CREATE FUNCTION public.detect_stock_anomalies()
RETURNS TABLE(
  product_id UUID,
  product_name TEXT,
  vendor_id UUID,
  current_stock INTEGER,
  anomaly_type TEXT,
  details JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    p.id as product_id,
    p.name as product_name,
    p.vendor_id,
    COALESCE(p.stock, 0) as current_stock,
    'NEGATIVE_STOCK'::TEXT as anomaly_type,
    jsonb_build_object('stock', p.stock) as details
  FROM products p
  WHERE COALESCE(p.stock, 0) < 0;

  RETURN QUERY
  SELECT 
    p.id as product_id,
    p.name as product_name,
    p.vendor_id,
    COALESCE(p.stock, 0) as current_stock,
    'UNUSUALLY_HIGH_STOCK'::TEXT as anomaly_type,
    jsonb_build_object('stock', p.stock, 'threshold', 100000) as details
  FROM products p
  WHERE COALESCE(p.stock, 0) > 100000;
END;
$$;

-- 3. COMMANDES: Détection des incohérences de statut
CREATE FUNCTION public.detect_order_anomalies()
RETURNS TABLE(
  order_id UUID,
  order_number TEXT,
  anomaly_type TEXT,
  current_status TEXT,
  expected_status TEXT,
  details JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    o.id as order_id,
    o.order_number,
    'STALE_PAID_ORDER'::TEXT as anomaly_type,
    o.status as current_status,
    'processing'::TEXT as expected_status,
    jsonb_build_object(
      'paid_at', o.paid_at,
      'days_stale', EXTRACT(DAY FROM NOW() - o.paid_at)
    ) as details
  FROM orders o
  WHERE o.payment_status = 'paid' 
    AND o.status = 'pending'
    AND o.paid_at < NOW() - INTERVAL '24 hours';

  RETURN QUERY
  SELECT 
    o.id as order_id,
    o.order_number,
    'DELIVERED_UNPAID'::TEXT as anomaly_type,
    o.status as current_status,
    'paid_required'::TEXT as expected_status,
    jsonb_build_object(
      'payment_status', o.payment_status,
      'delivered_at', o.updated_at
    ) as details
  FROM orders o
  WHERE o.status = 'delivered' 
    AND o.payment_status != 'paid';
END;
$$;

-- 4. COMMISSIONS: Détection des commissions non calculées
CREATE FUNCTION public.detect_commission_anomalies()
RETURNS TABLE(
  agent_id UUID,
  agent_name TEXT,
  anomaly_type TEXT,
  details JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    am.id as agent_id,
    am.name as agent_name,
    'MISSING_COMMISSIONS'::TEXT as anomaly_type,
    jsonb_build_object(
      'users_created', (SELECT COUNT(*) FROM agent_created_users acu WHERE acu.agent_id = am.id),
      'commissions_count', (SELECT COUNT(*) FROM agent_affiliate_commissions aac WHERE aac.agent_id = am.id)
    ) as details
  FROM agents_management am
  WHERE am.is_active = true
    AND (SELECT COUNT(*) FROM agent_created_users acu WHERE acu.agent_id = am.id) > 0
    AND (SELECT COUNT(*) FROM agent_affiliate_commissions aac WHERE aac.agent_id = am.id) = 0;

  RETURN QUERY
  SELECT 
    aac.agent_id,
    am.name as agent_name,
    'STALE_PENDING_COMMISSION'::TEXT as anomaly_type,
    jsonb_build_object(
      'commission_id', aac.id,
      'amount', aac.commission_amount,
      'pending_since', aac.created_at,
      'days_pending', EXTRACT(DAY FROM NOW() - aac.created_at)
    ) as details
  FROM agent_affiliate_commissions aac
  JOIN agents_management am ON am.id = aac.agent_id
  WHERE aac.status = 'pending'
    AND aac.created_at < NOW() - INTERVAL '7 days';
END;
$$;

-- 5. UTILISATEURS: Détection des incohérences de profils
CREATE FUNCTION public.detect_user_anomalies()
RETURNS TABLE(
  user_id UUID,
  public_id TEXT,
  anomaly_type TEXT,
  details JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    p.id as user_id,
    p.public_id,
    'MISSING_PUBLIC_ID'::TEXT as anomaly_type,
    jsonb_build_object('email', p.email, 'role', p.role) as details
  FROM profiles p
  WHERE p.public_id IS NULL OR p.public_id = '';

  RETURN QUERY
  SELECT 
    p.id as user_id,
    p.public_id,
    'ID_SYNC_MISMATCH'::TEXT as anomaly_type,
    jsonb_build_object(
      'profile_public_id', p.public_id,
      'user_ids_custom_id', ui.custom_id
    ) as details
  FROM profiles p
  LEFT JOIN user_ids ui ON ui.user_id = p.id
  WHERE p.public_id IS NOT NULL 
    AND ui.custom_id IS NOT NULL 
    AND p.public_id != ui.custom_id;

  RETURN QUERY
  SELECT 
    p.id as user_id,
    p.public_id,
    'ROLE_TABLE_MISMATCH'::TEXT as anomaly_type,
    jsonb_build_object('profile_role', p.role) as details
  FROM profiles p
  LEFT JOIN user_roles ur ON ur.user_id = p.id
  WHERE p.role IS NOT NULL 
    AND p.role != 'user'
    AND ur.id IS NULL;
END;
$$;

-- 6. BANKING: Détection des incohérences du ledger
CREATE FUNCTION public.detect_ledger_anomalies()
RETURNS TABLE(
  entity_id UUID,
  entity_type TEXT,
  anomaly_type TEXT,
  ledger_balance NUMERIC,
  wallet_balance NUMERIC,
  difference NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    fl.entity_id,
    fl.entity_type,
    'LEDGER_WALLET_MISMATCH'::TEXT as anomaly_type,
    fl.balance as ledger_balance,
    COALESCE(uw.balance, 0) as wallet_balance,
    fl.balance - COALESCE(uw.balance, 0) as difference
  FROM financial_ledger fl
  LEFT JOIN user_wallets uw ON uw.user_id = fl.entity_id
  WHERE fl.entity_type = 'user'
    AND ABS(fl.balance - COALESCE(uw.balance, 0)) > 0.01;

  RETURN QUERY
  SELECT 
    fq.id as entity_id,
    'quarantine'::TEXT as entity_type,
    'STALE_QUARANTINE'::TEXT as anomaly_type,
    fq.amount as ledger_balance,
    0::NUMERIC as wallet_balance,
    fq.amount as difference
  FROM financial_quarantine fq
  WHERE fq.status = 'pending'
    AND fq.created_at < NOW() - INTERVAL '48 hours';
END;
$$;

-- 7. FONCTION GLOBALE: Exécuter toutes les détections
CREATE FUNCTION public.run_global_anomaly_detection(
  p_domains TEXT[] DEFAULT NULL
)
RETURNS TABLE(
  domain TEXT,
  anomalies_found INTEGER,
  critical_count INTEGER,
  high_count INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_domains TEXT[];
  v_domain TEXT;
  v_count INTEGER;
BEGIN
  IF p_domains IS NULL THEN
    v_domains := ARRAY['FINANCE', 'STOCK', 'ORDERS', 'COMMISSIONS', 'USERS', 'BANKING', 'PERMISSIONS'];
  ELSE
    v_domains := p_domains;
  END IF;

  FOREACH v_domain IN ARRAY v_domains LOOP
    v_count := 0;
    
    CASE v_domain
      WHEN 'FINANCE' THEN
        INSERT INTO logic_anomalies (rule_id, domain, severity, expected_value, actual_value, affected_entities)
        SELECT 
          'FIN_001',
          'FINANCE',
          CASE WHEN ABS(wba.difference) > 1000 THEN 'CRITICAL' WHEN ABS(wba.difference) > 100 THEN 'HIGH' ELSE 'MEDIUM' END,
          jsonb_build_object('balance', wba.calculated_balance),
          jsonb_build_object('balance', wba.stored_balance),
          jsonb_build_array(jsonb_build_object('wallet_id', wba.wallet_id, 'type', wba.wallet_type))
        FROM detect_wallet_balance_anomalies() wba
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_count = ROW_COUNT;
        
      WHEN 'STOCK' THEN
        INSERT INTO logic_anomalies (rule_id, domain, severity, expected_value, actual_value, affected_entities)
        SELECT 
          'STK_001',
          'STOCK',
          CASE WHEN sa.anomaly_type = 'NEGATIVE_STOCK' THEN 'CRITICAL' ELSE 'MEDIUM' END,
          jsonb_build_object('expected', 'positive_stock'),
          jsonb_build_object('current_stock', sa.current_stock, 'anomaly', sa.anomaly_type),
          jsonb_build_array(jsonb_build_object('product_id', sa.product_id, 'name', sa.product_name))
        FROM detect_stock_anomalies() sa
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_count = ROW_COUNT;

      WHEN 'ORDERS' THEN
        INSERT INTO logic_anomalies (rule_id, domain, severity, expected_value, actual_value, affected_entities)
        SELECT 
          'ORD_001',
          'ORDERS',
          CASE WHEN oa.anomaly_type = 'DELIVERED_UNPAID' THEN 'CRITICAL' ELSE 'HIGH' END,
          jsonb_build_object('expected_status', oa.expected_status),
          jsonb_build_object('current_status', oa.current_status, 'anomaly', oa.anomaly_type),
          jsonb_build_array(jsonb_build_object('order_id', oa.order_id, 'number', oa.order_number))
        FROM detect_order_anomalies() oa
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_count = ROW_COUNT;

      WHEN 'COMMISSIONS' THEN
        INSERT INTO logic_anomalies (rule_id, domain, severity, expected_value, actual_value, affected_entities)
        SELECT 
          'COM_001',
          'COMMISSIONS',
          CASE WHEN ca.anomaly_type = 'STALE_PENDING_COMMISSION' THEN 'HIGH' ELSE 'MEDIUM' END,
          jsonb_build_object('expected', 'commissions_calculated'),
          ca.details,
          jsonb_build_array(jsonb_build_object('agent_id', ca.agent_id, 'name', ca.agent_name))
        FROM detect_commission_anomalies() ca
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_count = ROW_COUNT;

      WHEN 'USERS' THEN
        INSERT INTO logic_anomalies (rule_id, domain, severity, expected_value, actual_value, affected_entities)
        SELECT 
          'USR_001',
          'USERS',
          CASE 
            WHEN ua.anomaly_type = 'ROLE_TABLE_MISMATCH' THEN 'CRITICAL'
            WHEN ua.anomaly_type = 'ID_SYNC_MISMATCH' THEN 'HIGH'
            ELSE 'MEDIUM' 
          END,
          jsonb_build_object('expected', 'consistent_user_data'),
          ua.details,
          jsonb_build_array(jsonb_build_object('user_id', ua.user_id, 'public_id', ua.public_id))
        FROM detect_user_anomalies() ua
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_count = ROW_COUNT;

      WHEN 'BANKING' THEN
        INSERT INTO logic_anomalies (rule_id, domain, severity, expected_value, actual_value, affected_entities)
        SELECT 
          'BNK_001',
          'BANKING',
          CASE 
            WHEN la.anomaly_type = 'STALE_QUARANTINE' THEN 'CRITICAL'
            WHEN ABS(la.difference) > 1000 THEN 'CRITICAL'
            ELSE 'HIGH'
          END,
          jsonb_build_object('ledger_balance', la.ledger_balance),
          jsonb_build_object('wallet_balance', la.wallet_balance, 'difference', la.difference),
          jsonb_build_array(jsonb_build_object('entity_id', la.entity_id, 'type', la.entity_type))
        FROM detect_ledger_anomalies() la
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_count = ROW_COUNT;

      WHEN 'PERMISSIONS' THEN
        PERFORM run_permission_sync_validation();
        v_count := 0;

      ELSE
        v_count := 0;
    END CASE;

    domain := v_domain;
    anomalies_found := v_count;
    critical_count := (
      SELECT COUNT(*)::INTEGER FROM logic_anomalies la2 
      WHERE la2.domain = v_domain 
      AND la2.severity = 'CRITICAL' 
      AND la2.resolved_at IS NULL
    );
    high_count := (
      SELECT COUNT(*)::INTEGER FROM logic_anomalies la2 
      WHERE la2.domain = v_domain 
      AND la2.severity = 'HIGH' 
      AND la2.resolved_at IS NULL
    );
    RETURN NEXT;
  END LOOP;
END;
$$;

-- 8. MISE À JOUR de get_system_health
CREATE FUNCTION public.get_system_health()
RETURNS TABLE(
  overall_status TEXT,
  total_rules INTEGER,
  total_anomalies INTEGER,
  critical_anomalies INTEGER,
  high_anomalies INTEGER,
  recent_anomalies_24h INTEGER,
  resolution_rate NUMERIC,
  domain_breakdown JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_critical INTEGER;
  v_high INTEGER;
  v_total INTEGER;
  v_resolved INTEGER;
  v_recent INTEGER;
  v_rules INTEGER;
BEGIN
  SELECT COUNT(*)::INTEGER INTO v_rules FROM logic_rules WHERE enabled = true;
  SELECT COUNT(*)::INTEGER INTO v_total FROM logic_anomalies WHERE resolved_at IS NULL;
  SELECT COUNT(*)::INTEGER INTO v_critical FROM logic_anomalies WHERE severity = 'CRITICAL' AND resolved_at IS NULL;
  SELECT COUNT(*)::INTEGER INTO v_high FROM logic_anomalies WHERE severity = 'HIGH' AND resolved_at IS NULL;
  SELECT COUNT(*)::INTEGER INTO v_resolved FROM logic_anomalies WHERE resolved_at IS NOT NULL;
  SELECT COUNT(*)::INTEGER INTO v_recent FROM logic_anomalies WHERE detected_at > NOW() - INTERVAL '24 hours';

  overall_status := CASE 
    WHEN v_critical > 0 THEN 'CRITICAL'
    WHEN v_high > 0 THEN 'WARNING'
    ELSE 'OK'
  END;
  
  total_rules := v_rules;
  total_anomalies := v_total;
  critical_anomalies := v_critical;
  high_anomalies := v_high;
  recent_anomalies_24h := v_recent;
  resolution_rate := CASE WHEN (v_total + v_resolved) > 0 
    THEN ROUND((v_resolved::NUMERIC / (v_total + v_resolved)) * 100, 2) 
    ELSE 100 
  END;
  
  domain_breakdown := COALESCE((
    SELECT jsonb_object_agg(la.domain, la.count)
    FROM (
      SELECT la2.domain, COUNT(*)::INTEGER as count 
      FROM logic_anomalies la2 
      WHERE la2.resolved_at IS NULL 
      GROUP BY la2.domain
    ) la
  ), '{}'::jsonb);

  RETURN NEXT;
END;
$$;

-- 9. INSERTION DES RÈGLES (avec les bonnes colonnes)
INSERT INTO logic_rules (rule_id, domain, name, description, severity, expected_logic, detection_method, auto_correctable, enabled, parameters)
VALUES 
  ('FIN_001', 'FINANCE', 'Balance Reconciliation', 'Wallet balance must equal sum of transactions', 'CRITICAL', 
   '{"rule": "wallet_balance_equals_sum_transactions", "tolerance": 0.01}'::jsonb,
   'RPC:detect_wallet_balance_anomalies', false, true,
   '{"check_interval_hours": 1}'::jsonb),
   
  ('STK_001', 'STOCK', 'Stock Integrity', 'Stock must be positive or zero', 'CRITICAL',
   '{"rule": "stock_must_be_positive_or_zero", "max_threshold": 100000}'::jsonb,
   'RPC:detect_stock_anomalies', false, true,
   '{"check_interval_hours": 6}'::jsonb),
   
  ('ORD_001', 'ORDERS', 'Order Status Consistency', 'Order status must be consistent with payment', 'HIGH',
   '{"rule": "order_status_consistency", "paid_processing_delay_hours": 24}'::jsonb,
   'RPC:detect_order_anomalies', false, true,
   '{"check_interval_hours": 4}'::jsonb),
   
  ('COM_001', 'COMMISSIONS', 'Commission Calculation', 'Commissions must be calculated for agent users', 'MEDIUM',
   '{"rule": "commissions_must_be_calculated", "pending_threshold_days": 7}'::jsonb,
   'RPC:detect_commission_anomalies', true, true,
   '{"check_interval_hours": 24}'::jsonb),
   
  ('USR_001', 'USERS', 'User Data Consistency', 'User data must be synchronized across tables', 'HIGH',
   '{"rule": "user_data_consistency", "require_public_id": true, "require_role_sync": true}'::jsonb,
   'RPC:detect_user_anomalies', true, true,
   '{"check_interval_hours": 12}'::jsonb),
   
  ('BNK_001', 'BANKING', 'Ledger Consistency', 'Ledger must match wallet balances', 'CRITICAL',
   '{"rule": "ledger_wallet_consistency", "quarantine_threshold_hours": 48}'::jsonb,
   'RPC:detect_ledger_anomalies', false, true,
   '{"check_interval_hours": 1}'::jsonb)
ON CONFLICT (rule_id) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  expected_logic = EXCLUDED.expected_logic,
  detection_method = EXCLUDED.detection_method,
  parameters = EXCLUDED.parameters,
  updated_at = NOW();
