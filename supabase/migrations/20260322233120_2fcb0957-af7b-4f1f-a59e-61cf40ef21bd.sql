-- ============================================
-- FIX 1: Drop overly permissive SELECT policies exposing password_hash
-- ============================================
DROP POLICY IF EXISTS "Anyone can view agent with valid access_token" ON agents_management;
DROP POLICY IF EXISTS "Public can view members with valid bureau" ON members;

-- ============================================
-- FIX 2: Convert SECURITY DEFINER views to SECURITY INVOKER
-- ============================================
ALTER VIEW admin_payment_review_queue SET (security_invoker = true);
ALTER VIEW agent_commission_stats SET (security_invoker = true);
ALTER VIEW audio_translation_stats SET (security_invoker = true);
ALTER VIEW id_normalization_stats SET (security_invoker = true);
ALTER VIEW interface_status SET (security_invoker = true);
ALTER VIEW logic_validation_rules SET (security_invoker = true);
ALTER VIEW payment_core_view SET (security_invoker = true);
ALTER VIEW pdg_interface_stats SET (security_invoker = true);
ALTER VIEW pdg_vehicle_security_overview SET (security_invoker = true);
ALTER VIEW presence_stats SET (security_invoker = true);
ALTER VIEW security_policy_summary SET (security_invoker = true);
ALTER VIEW security_stats SET (security_invoker = true);
ALTER VIEW system_alerts_summary SET (security_invoker = true);
ALTER VIEW user_codes_unified SET (security_invoker = true);
ALTER VIEW user_search_view SET (security_invoker = true);
ALTER VIEW v_active_transfers SET (security_invoker = true);
ALTER VIEW v_product_stock_summary SET (security_invoker = true);
ALTER VIEW v_recent_losses SET (security_invoker = true);
ALTER VIEW v_stock_by_location SET (security_invoker = true);
ALTER VIEW vendor_product_analytics SET (security_invoker = true);
ALTER VIEW vendor_profit_stats SET (security_invoker = true);
ALTER VIEW wallet_summary SET (security_invoker = true);