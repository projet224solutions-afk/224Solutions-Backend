-- ===========================================
-- SECURITY FIXES - Add search_path to functions
-- ===========================================

-- Fix auto_resolve_cache_errors - use ALTER to set search_path
ALTER FUNCTION public.auto_resolve_cache_errors() SET search_path = public;

-- Fix check_service_owner - already has correct return type
ALTER FUNCTION public.check_service_owner(uuid) SET search_path = public;

-- Fix notify_driver_package_ready
ALTER FUNCTION public.notify_driver_package_ready() SET search_path = public;

-- Fix notify_vendor_on_driver_accept
ALTER FUNCTION public.notify_vendor_on_driver_accept() SET search_path = public;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION public.auto_resolve_cache_errors() TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_service_owner(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.notify_driver_package_ready() TO service_role;
GRANT EXECUTE ON FUNCTION public.notify_vendor_on_driver_accept() TO service_role;