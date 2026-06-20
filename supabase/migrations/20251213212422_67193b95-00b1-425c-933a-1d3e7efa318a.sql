-- =====================================================
-- SÉCURITÉ 100% - RECRÉATION VUES AVEC SECURITY INVOKER
-- =====================================================

-- 1. system_dashboard (corrigé avec wallet_status)
DROP VIEW IF EXISTS system_dashboard CASCADE;
CREATE VIEW system_dashboard WITH (security_invoker = true) AS
SELECT 
    (SELECT count(*) FROM system_errors WHERE status = 'pending') AS pending_errors,
    (SELECT count(*) FROM security_alerts WHERE acknowledged = false) AS active_security_alerts,
    (SELECT count(*) FROM pdg_financial_alerts WHERE is_read = false) AS unread_financial_alerts,
    (SELECT COALESCE(AVG(CASE WHEN wallet_status = 'active' THEN 100 ELSE 0 END), 100) FROM wallets) AS system_health;
GRANT SELECT ON system_dashboard TO authenticated;

-- 2. agent_type_statistics
DROP VIEW IF EXISTS agent_type_statistics CASCADE;
CREATE VIEW agent_type_statistics WITH (security_invoker = true) AS
SELECT pdg_id,
    type_agent,
    count(*) AS total_agents,
    count(CASE WHEN is_active THEN 1 ELSE NULL END) AS active_agents,
    sum(commission_rate) AS total_commission_rate
FROM agents_management
GROUP BY pdg_id, type_agent;
GRANT SELECT ON agent_type_statistics TO authenticated;

-- 3. bureau_pwa_stats
DROP VIEW IF EXISTS bureau_pwa_stats CASCADE;
CREATE VIEW bureau_pwa_stats WITH (security_invoker = true) AS
SELECT b.id AS bureau_id,
    b.prefecture,
    b.commune,
    count(DISTINCT pi.id) AS total_installations,
    count(DISTINCT CASE WHEN (pi.installed_at > (now() - '30 days'::interval)) THEN pi.id ELSE NULL END) AS recent_installations,
    count(DISTINCT CASE WHEN (pi.is_mobile = true) THEN pi.id ELSE NULL END) AS mobile_installations,
    count(DISTINCT CASE WHEN (pi.is_mobile = false) THEN pi.id ELSE NULL END) AS desktop_installations,
    max(pi.installed_at) AS last_installation,
    count(DISTINCT pt.id) AS total_tokens_generated,
    count(DISTINCT CASE WHEN (pt.used = true) THEN pt.id ELSE NULL END) AS tokens_used,
    count(DISTINCT bal.id) AS total_access_attempts
FROM bureaus b
LEFT JOIN pwa_installations pi ON (b.id = pi.bureau_id)
LEFT JOIN pwa_tokens pt ON (b.id = pt.bureau_id)
LEFT JOIN bureau_access_logs bal ON (b.id = bal.bureau_id)
GROUP BY b.id, b.prefecture, b.commune;
GRANT SELECT ON bureau_pwa_stats TO authenticated;

-- 4. bureau_security_stats
DROP VIEW IF EXISTS bureau_security_stats CASCADE;
CREATE VIEW bureau_security_stats WITH (security_invoker = true) AS
SELECT b.id AS bureau_id,
    b.bureau_code,
    b.commune,
    count(v.id) FILTER (WHERE (v.stolen_status = 'stolen')) AS active_thefts,
    count(v.id) FILTER (WHERE (v.stolen_status = 'recovered')) AS recovered_count,
    count(vfa.id) FILTER (WHERE (vfa.is_resolved = false)) AS pending_alerts,
    (SELECT count(*) FROM vehicle_security_log vsl WHERE vsl.bureau_id = b.id AND vsl.created_at > (now() - '30 days'::interval)) AS security_events_30d
FROM bureaus b
LEFT JOIN vehicles v ON (v.bureau_id = b.id)
LEFT JOIN vehicle_fraud_alerts vfa ON (vfa.vehicle_id = v.id)
GROUP BY b.id, b.bureau_code, b.commune;
GRANT SELECT ON bureau_security_stats TO authenticated;

-- 5. pdg_dashboard_overview
DROP VIEW IF EXISTS pdg_dashboard_overview CASCADE;
CREATE VIEW pdg_dashboard_overview WITH (security_invoker = true) AS
SELECT 
    (SELECT count(*) FROM profiles) AS total_users,
    (SELECT count(*) FROM profiles WHERE role = 'vendeur') AS total_vendors,
    (SELECT count(*) FROM profiles WHERE role = 'client') AS total_clients,
    (SELECT count(*) FROM profiles WHERE role = 'livreur') AS total_drivers,
    (SELECT count(*) FROM bureaus) AS total_bureaus,
    (SELECT count(*) FROM agents_management WHERE is_active = true) AS total_agents,
    (SELECT COALESCE(SUM(balance), 0) FROM wallets) AS total_wallet_balance,
    (SELECT count(*) FROM orders WHERE created_at > now() - interval '24 hours') AS orders_24h,
    (SELECT count(*) FROM deliveries WHERE created_at > now() - interval '24 hours') AS deliveries_24h;
GRANT SELECT ON pdg_dashboard_overview TO authenticated;

-- 6. vendor_performance
DROP VIEW IF EXISTS vendor_performance CASCADE;
CREATE VIEW vendor_performance WITH (security_invoker = true) AS
SELECT 
    v.id AS vendor_id,
    v.business_name,
    v.user_id,
    count(DISTINCT o.id) AS total_orders,
    count(DISTINCT p.id) AS total_products,
    COALESCE(SUM(o.total_amount), 0) AS total_revenue,
    COALESCE(AVG(vr.rating), 0) AS avg_rating
FROM vendors v
LEFT JOIN orders o ON o.vendor_id = v.id
LEFT JOIN products p ON p.vendor_id = v.id
LEFT JOIN vendor_ratings vr ON vr.vendor_id = v.id
GROUP BY v.id, v.business_name, v.user_id;
GRANT SELECT ON vendor_performance TO authenticated;

-- 7. wallet_summary
DROP VIEW IF EXISTS wallet_summary CASCADE;
CREATE VIEW wallet_summary WITH (security_invoker = true) AS
SELECT 
    'user' AS wallet_type,
    count(*) AS total_wallets,
    COALESCE(SUM(balance), 0) AS total_balance,
    COALESCE(AVG(balance), 0) AS avg_balance
FROM wallets WHERE wallet_status = 'active'
UNION ALL
SELECT 
    'agent' AS wallet_type,
    count(*) AS total_wallets,
    COALESCE(SUM(balance), 0) AS total_balance,
    COALESCE(AVG(balance), 0) AS avg_balance
FROM agent_wallets WHERE wallet_status = 'active'
UNION ALL
SELECT 
    'bureau' AS wallet_type,
    count(*) AS total_wallets,
    COALESCE(SUM(balance), 0) AS total_balance,
    COALESCE(AVG(balance), 0) AS avg_balance
FROM bureau_wallets WHERE wallet_status = 'active';
GRANT SELECT ON wallet_summary TO authenticated;

-- 8. interface_status (simplifié)
DROP VIEW IF EXISTS interface_status CASCADE;
CREATE VIEW interface_status WITH (security_invoker = true) AS
SELECT 'Vendeurs'::text AS interface,
    (SELECT count(*) FROM profiles WHERE role = 'vendeur') AS active_users,
    (SELECT count(*) FROM products) AS transactions,
    0 AS errors,
    95 AS performance
UNION ALL
SELECT 'Clients'::text AS interface,
    (SELECT count(*) FROM profiles WHERE role = 'client') AS active_users,
    (SELECT count(*) FROM orders) AS transactions,
    0 AS errors,
    95 AS performance
UNION ALL
SELECT 'Livreurs'::text AS interface,
    (SELECT count(*) FROM profiles WHERE role = 'livreur') AS active_users,
    (SELECT count(*) FROM deliveries) AS transactions,
    0 AS errors,
    95 AS performance;
GRANT SELECT ON interface_status TO authenticated;