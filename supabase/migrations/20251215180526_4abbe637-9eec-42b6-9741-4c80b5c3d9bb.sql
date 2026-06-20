-- Recreate pdg_interface_stats view with ALL interfaces
DROP VIEW IF EXISTS pdg_interface_stats;

CREATE VIEW pdg_interface_stats WITH (security_invoker = true) AS
SELECT 'Vendeurs' AS interface,
    (SELECT COUNT(*) FROM profiles WHERE role = 'vendeur') AS users,
    (SELECT COUNT(*) FROM system_errors WHERE module ILIKE '%vendor%' AND status = 'pending') AS pending_alerts
UNION ALL
SELECT 'Clients' AS interface,
    (SELECT COUNT(*) FROM profiles WHERE role = 'client') AS users,
    (SELECT COUNT(*) FROM system_errors WHERE module ILIKE '%client%' AND status = 'pending') AS pending_alerts
UNION ALL
SELECT 'Livreurs' AS interface,
    (SELECT COUNT(*) FROM profiles WHERE role = 'livreur') AS users,
    (SELECT COUNT(*) FROM system_errors WHERE module ILIKE '%livr%' AND status = 'pending') AS pending_alerts
UNION ALL
SELECT 'Agents' AS interface,
    (SELECT COUNT(*) FROM profiles WHERE role = 'agent') AS users,
    (SELECT COUNT(*) FROM system_errors WHERE module ILIKE '%agent%' AND status = 'pending') AS pending_alerts
UNION ALL
SELECT 'Bureaux Syndicats' AS interface,
    (SELECT COUNT(*) FROM profiles WHERE role = 'syndicat') AS users,
    (SELECT COUNT(*) FROM system_errors WHERE module ILIKE '%bureau%' OR module ILIKE '%syndicat%' AND status = 'pending') AS pending_alerts
UNION ALL
SELECT 'Taxi-motos' AS interface,
    (SELECT COUNT(*) FROM profiles WHERE role = 'taxi') AS users,
    (SELECT COUNT(*) FROM system_errors WHERE module ILIKE '%taxi%' AND status = 'pending') AS pending_alerts
UNION ALL
SELECT 'Transitaires' AS interface,
    (SELECT COUNT(*) FROM profiles WHERE role = 'transitaire') AS users,
    (SELECT COUNT(*) FROM system_errors WHERE module ILIKE '%transit%' AND status = 'pending') AS pending_alerts
UNION ALL
SELECT 'PDG' AS interface,
    (SELECT COUNT(*) FROM profiles WHERE role = 'admin') AS users,
    (SELECT COUNT(*) FROM pdg_financial_alerts WHERE is_read = false) AS pending_alerts;

-- Grant access
GRANT SELECT ON pdg_interface_stats TO authenticated;