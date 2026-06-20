-- =====================================================
-- SÉCURITÉ 100% - DERNIÈRES VUES AVEC SECURITY INVOKER
-- =====================================================

-- 1. pdg_interface_stats
DROP VIEW IF EXISTS pdg_interface_stats CASCADE;
CREATE VIEW pdg_interface_stats WITH (security_invoker = true) AS
SELECT 
    'PDG' AS interface,
    (SELECT count(*) FROM profiles WHERE role = 'admin') AS users,
    (SELECT count(*) FROM pdg_financial_alerts WHERE is_read = false) AS pending_alerts;
GRANT SELECT ON pdg_interface_stats TO authenticated;

-- 2. pdg_vehicle_security_overview
DROP VIEW IF EXISTS pdg_vehicle_security_overview CASCADE;
CREATE VIEW pdg_vehicle_security_overview WITH (security_invoker = true) AS
SELECT 
    (SELECT count(*) FROM vehicles WHERE stolen_status = 'stolen') AS total_stolen,
    (SELECT count(*) FROM vehicles WHERE stolen_status = 'recovered') AS total_recovered,
    (SELECT count(*) FROM vehicle_fraud_alerts WHERE is_resolved = false) AS active_alerts;
GRANT SELECT ON pdg_vehicle_security_overview TO authenticated;

-- 3. security_stats  
DROP VIEW IF EXISTS security_stats CASCADE;
CREATE VIEW security_stats WITH (security_invoker = true) AS
SELECT 
    (SELECT count(*) FROM security_alerts WHERE acknowledged = false) AS unacknowledged_alerts,
    (SELECT count(*) FROM security_incidents) AS total_incidents,
    (SELECT count(*) FROM blocked_ips WHERE is_active = true) AS blocked_ips;
GRANT SELECT ON security_stats TO authenticated;

-- 4. system_alerts_summary
DROP VIEW IF EXISTS system_alerts_summary CASCADE;
CREATE VIEW system_alerts_summary WITH (security_invoker = true) AS
SELECT 
    severity,
    count(*) AS count
FROM system_alerts
GROUP BY severity;
GRANT SELECT ON system_alerts_summary TO authenticated;

-- 5. user_search_view
DROP VIEW IF EXISTS user_search_view CASCADE;
CREATE VIEW user_search_view WITH (security_invoker = true) AS
SELECT 
    p.id,
    p.email,
    p.first_name,
    p.last_name,
    p.phone,
    p.role,
    ui.custom_id,
    v.business_name,
    v.id AS vendor_id
FROM profiles p
LEFT JOIN user_ids ui ON ui.user_id = p.id
LEFT JOIN vendors v ON v.user_id = p.id;
GRANT SELECT ON user_search_view TO authenticated;

-- 6. wallet_admin_stats
DROP VIEW IF EXISTS wallet_admin_stats CASCADE;
CREATE VIEW wallet_admin_stats WITH (security_invoker = true) AS
SELECT 
    (SELECT count(*) FROM wallets) AS total_wallets,
    (SELECT COALESCE(SUM(balance), 0) FROM wallets) AS total_balance,
    (SELECT count(*) FROM wallet_transactions WHERE created_at > now() - interval '24 hours') AS transactions_24h,
    (SELECT count(*) FROM agent_wallets) AS agent_wallets,
    (SELECT count(*) FROM bureau_wallets) AS bureau_wallets;
GRANT SELECT ON wallet_admin_stats TO authenticated;