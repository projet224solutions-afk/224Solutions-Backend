-- Fix RLS for API Supervision / 224Guard access
-- Root cause: policies were restricted to admin only, blocking PDG/CEO visibility.

ALTER TABLE public.api_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.api_usage_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.api_alerts ENABLE ROW LEVEL SECURITY;

-- Clean up legacy policy variants
DROP POLICY IF EXISTS "PDG can manage api_connections" ON public.api_connections;
DROP POLICY IF EXISTS "admin_manage_api_connections" ON public.api_connections;

DROP POLICY IF EXISTS "PDG can view api_usage_logs" ON public.api_usage_logs;
DROP POLICY IF EXISTS "admin_view_api_usage_logs" ON public.api_usage_logs;
DROP POLICY IF EXISTS "Service role can insert api_usage_logs" ON public.api_usage_logs;

DROP POLICY IF EXISTS "PDG can manage api_alerts" ON public.api_alerts;
DROP POLICY IF EXISTS "admin_manage_api_alerts" ON public.api_alerts;
-- Shared role predicate (admin/pdg/ceo)
CREATE POLICY "core_supervision_manage_api_connections"
ON public.api_connections
FOR ALL TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.role IN ('admin', 'pdg', 'ceo')
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.role IN ('admin', 'pdg', 'ceo')
  )
);

CREATE POLICY "core_supervision_view_api_usage_logs"
ON public.api_usage_logs
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.role IN ('admin', 'pdg', 'ceo')
  )
);

CREATE POLICY "core_supervision_insert_api_usage_logs"
ON public.api_usage_logs
FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.role IN ('admin', 'pdg', 'ceo')
  )
);

CREATE POLICY "core_supervision_service_insert_api_usage_logs"
ON public.api_usage_logs
FOR INSERT
WITH CHECK (auth.jwt()->>'role' = 'service_role');

CREATE POLICY "core_supervision_manage_api_alerts"
ON public.api_alerts
FOR ALL TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.role IN ('admin', 'pdg', 'ceo')
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.role IN ('admin', 'pdg', 'ceo')
  )
);

CREATE POLICY "core_supervision_service_manage_api_alerts"
ON public.api_alerts
FOR ALL
USING (auth.jwt()->>'role' = 'service_role')
WITH CHECK (auth.jwt()->>'role' = 'service_role');
