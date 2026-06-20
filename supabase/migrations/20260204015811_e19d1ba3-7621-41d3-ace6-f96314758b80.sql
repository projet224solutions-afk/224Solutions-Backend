-- Corriger la fonction get_pdg_dashboard_stats pour accepter les rôles admin, pdg et ceo
CREATE OR REPLACE FUNCTION get_pdg_dashboard_stats()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSON;
  v_is_admin BOOLEAN;
BEGIN
  -- Vérifier que l'utilisateur est admin, pdg ou ceo
  SELECT EXISTS (
    SELECT 1 FROM profiles 
    WHERE id = auth.uid() 
    AND LOWER(role) IN ('admin', 'pdg', 'ceo')
  ) INTO v_is_admin;

  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'Access denied: admin/pdg/ceo role required';
  END IF;

  -- Construire les statistiques
  SELECT json_build_object(
    'total_users', (SELECT COUNT(*) FROM profiles),
    'total_vendors', (SELECT COUNT(*) FROM profiles WHERE role = 'vendeur'),
    'total_clients', (SELECT COUNT(*) FROM profiles WHERE role = 'client'),
    'total_drivers', (SELECT COUNT(*) FROM profiles WHERE role = 'livreur'),
    'total_agents', (SELECT COUNT(*) FROM profiles WHERE role = 'agent'),
    'total_products', (SELECT COUNT(*) FROM products),
    'total_orders', (SELECT COUNT(*) FROM orders),
    'total_deliveries', (SELECT COUNT(*) FROM deliveries),
    'total_errors', COALESCE((SELECT COUNT(*) FROM system_errors), 0),
    'critical_errors', COALESCE((SELECT COUNT(*) FROM system_errors WHERE severity = 'critique'), 0),
    'pending_errors', COALESCE((SELECT COUNT(*) FROM system_errors WHERE status = 'detected'), 0),
    'fixed_errors', COALESCE((SELECT COUNT(*) FROM system_errors WHERE fix_applied = true), 0)
  ) INTO v_result;

  RETURN v_result;
END;
$$;