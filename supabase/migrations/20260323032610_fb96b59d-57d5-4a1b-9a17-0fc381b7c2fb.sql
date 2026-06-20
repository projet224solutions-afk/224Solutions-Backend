CREATE OR REPLACE FUNCTION public.get_pdg_dashboard_stats()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result JSON;
  v_is_admin BOOLEAN;
BEGIN
  -- Vérifier que l'utilisateur est admin, pdg ou ceo (cast enum to text for LOWER)
  SELECT EXISTS (
    SELECT 1 FROM profiles 
    WHERE id = auth.uid() 
    AND LOWER(role::text) IN ('admin', 'pdg', 'ceo')
  ) INTO v_is_admin;

  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'Access denied: admin/pdg/ceo role required';
  END IF;

  -- Construire les statistiques
  SELECT json_build_object(
    'total_users', (SELECT COUNT(*) FROM profiles),
    'total_vendors', (SELECT COUNT(*) FROM profiles WHERE role::text = 'vendeur'),
    'total_clients', (SELECT COUNT(*) FROM profiles WHERE role::text = 'client'),
    'total_drivers', (SELECT COUNT(*) FROM profiles WHERE role::text = 'livreur'),
    'total_agents', (SELECT COUNT(*) FROM profiles WHERE role::text = 'agent'),
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
$function$;