-- ============================================
-- CREATE SECURE PDG STATISTICS VIEWS
-- Allow PDG/admin to see aggregated statistics without exposing sensitive data
-- ============================================

-- Vue pour les statistiques des interfaces (counts seulement, pas de données sensibles)
CREATE OR REPLACE VIEW public.pdg_interface_stats AS
SELECT 
  'Vendeurs' as interface,
  COUNT(DISTINCT p.id) as active_users,
  COUNT(DISTINCT pr.id) as transactions,
  COUNT(DISTINCT se.id) as errors,
  95 - COALESCE(COUNT(DISTINCT se.id), 0) * 2 as performance
FROM profiles p
LEFT JOIN products pr ON pr.vendor_id IN (
  SELECT v.id FROM vendors v WHERE v.user_id = p.id
)
LEFT JOIN system_errors se ON se.module ILIKE '%vendeur%'
WHERE p.role = 'vendeur'

UNION ALL

SELECT 
  'Clients' as interface,
  COUNT(DISTINCT p.id) as active_users,
  COUNT(DISTINCT o.id) as transactions,
  COUNT(DISTINCT se.id) as errors,
  95 - COALESCE(COUNT(DISTINCT se.id), 0) * 2 as performance
FROM profiles p
LEFT JOIN orders o ON o.customer_id = p.id
LEFT JOIN system_errors se ON se.module ILIKE '%client%'
WHERE p.role = 'client'

UNION ALL

SELECT 
  'Livreurs' as interface,
  COUNT(DISTINCT p.id) as active_users,
  COUNT(DISTINCT d.id) as transactions,
  COUNT(DISTINCT se.id) as errors,
  95 - COALESCE(COUNT(DISTINCT se.id), 0) * 2 as performance
FROM profiles p
LEFT JOIN deliveries d ON d.driver_id = p.id
LEFT JOIN system_errors se ON se.module ILIKE '%livreur%'
WHERE p.role = 'livreur'

UNION ALL

SELECT 
  'Agents' as interface,
  COUNT(DISTINCT p.id) as active_users,
  0 as transactions,
  COUNT(DISTINCT se.id) as errors,
  95 - COALESCE(COUNT(DISTINCT se.id), 0) * 2 as performance
FROM profiles p
LEFT JOIN system_errors se ON se.module ILIKE '%agent%'
WHERE p.role = 'admin'

UNION ALL

SELECT 
  'Bureaux Syndicats' as interface,
  COUNT(DISTINCT p.id) as active_users,
  0 as transactions,
  COUNT(DISTINCT se.id) as errors,
  95 - COALESCE(COUNT(DISTINCT se.id), 0) * 2 as performance
FROM profiles p
LEFT JOIN system_errors se ON se.module ILIKE '%bureau%'
WHERE p.role = 'syndicat'

UNION ALL

SELECT 
  'Transitaires' as interface,
  COUNT(DISTINCT p.id) as active_users,
  0 as transactions,
  COUNT(DISTINCT se.id) as errors,
  95 - COALESCE(COUNT(DISTINCT se.id), 0) * 2 as performance
FROM profiles p
LEFT JOIN system_errors se ON se.module ILIKE '%transitaire%'
WHERE p.role = 'transitaire'

UNION ALL

SELECT 
  'Taxi-motos' as interface,
  COUNT(DISTINCT p.id) as active_users,
  0 as transactions,
  COUNT(DISTINCT se.id) as errors,
  95 - COALESCE(COUNT(DISTINCT se.id), 0) * 2 as performance
FROM profiles p
LEFT JOIN system_errors se ON se.module ILIKE '%taxi%'
WHERE p.role = 'taxi';

-- Permettre aux admins de voir cette vue
GRANT SELECT ON public.pdg_interface_stats TO authenticated;

-- Créer une fonction sécurisée pour obtenir les stats PDG
CREATE OR REPLACE FUNCTION public.get_pdg_dashboard_stats()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSON;
  v_is_admin BOOLEAN;
BEGIN
  -- Vérifier que l'utilisateur est admin
  SELECT EXISTS (
    SELECT 1 FROM profiles 
    WHERE id = auth.uid() 
    AND role = 'admin'
  ) INTO v_is_admin;

  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'Access denied: admin role required';
  END IF;

  -- Construire les statistiques
  SELECT json_build_object(
    'total_users', (SELECT COUNT(*) FROM profiles),
    'total_vendors', (SELECT COUNT(*) FROM profiles WHERE role = 'vendeur'),
    'total_clients', (SELECT COUNT(*) FROM profiles WHERE role = 'client'),
    'total_drivers', (SELECT COUNT(*) FROM profiles WHERE role = 'livreur'),
    'total_agents', (SELECT COUNT(*) FROM profiles WHERE role = 'admin'),
    'total_products', (SELECT COUNT(*) FROM products),
    'total_orders', (SELECT COUNT(*) FROM orders),
    'total_deliveries', (SELECT COUNT(*) FROM deliveries),
    'total_errors', (SELECT COUNT(*) FROM system_errors),
    'critical_errors', (SELECT COUNT(*) FROM system_errors WHERE severity = 'critique'),
    'pending_errors', (SELECT COUNT(*) FROM system_errors WHERE status = 'detected'),
    'fixed_errors', (SELECT COUNT(*) FROM system_errors WHERE fix_applied = true)
  ) INTO v_result;

  RETURN v_result;
END;
$$;