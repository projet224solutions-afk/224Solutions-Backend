-- ============================================
-- FIX SYSTEM_SETTINGS SECURITY VULNERABILITY
-- Restrict access to system settings (commission rates, pricing, PDG wallet)
-- ============================================

-- Drop the overly permissive policy that allows anyone to view system settings
DROP POLICY IF EXISTS "Anyone can view system settings" ON public.system_settings;

-- Only PDG/admin can view system settings
CREATE POLICY "Admins can view system settings" ON public.system_settings
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = (SELECT auth.uid())
      AND profiles.role = 'admin'
    )
  );

-- Service role can access everything (for backend operations)
CREATE POLICY "Service role can manage system settings" ON public.system_settings
  FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');