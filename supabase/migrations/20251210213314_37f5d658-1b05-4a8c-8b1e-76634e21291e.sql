-- =============================================
-- TABLES MONITORING SYSTEM - Tables requises pour le fonctionnement
-- =============================================

-- 1. Table error_logs - Stockage des erreurs système
CREATE TABLE IF NOT EXISTS public.error_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    level VARCHAR(20) NOT NULL DEFAULT 'info',
    category VARCHAR(100) NOT NULL,
    message TEXT NOT NULL,
    metadata JSONB,
    resolved BOOLEAN DEFAULT false,
    resolved_at TIMESTAMPTZ,
    resolved_by UUID,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- 2. Table system_health_logs - Historique des health checks
CREATE TABLE IF NOT EXISTS public.system_health_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    overall_status VARCHAR(20) NOT NULL,
    security_status VARCHAR(20),
    database_status VARCHAR(20),
    api_status VARCHAR(20),
    frontend_status VARCHAR(20),
    critical_errors INTEGER DEFAULT 0,
    pending_errors INTEGER DEFAULT 0,
    uptime BIGINT,
    response_time INTEGER,
    active_users INTEGER DEFAULT 0,
    timestamp TIMESTAMPTZ DEFAULT now()
);

-- 3. Table health_check_reports - Rapports détaillés des health checks
CREATE TABLE IF NOT EXISTS public.health_check_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    overall_status VARCHAR(20) NOT NULL,
    checks JSONB NOT NULL,
    uptime BIGINT,
    checks_performed INTEGER,
    checks_passed INTEGER,
    checks_failed INTEGER,
    timestamp TIMESTAMPTZ DEFAULT now()
);

-- 4. Table performance_metrics - Métriques de performance
CREATE TABLE IF NOT EXISTS public.performance_metrics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    endpoint VARCHAR(255),
    method VARCHAR(10),
    response_time INTEGER,
    status_code INTEGER,
    user_id UUID,
    timestamp TIMESTAMPTZ DEFAULT now()
);

-- 5. Table secure_logs - Logs sécurisés
CREATE TABLE IF NOT EXISTS public.secure_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    level VARCHAR(20) NOT NULL,
    category VARCHAR(100) NOT NULL,
    message TEXT NOT NULL,
    metadata JSONB,
    user_id UUID,
    ip_address VARCHAR(45),
    user_agent TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Index pour performance
CREATE INDEX IF NOT EXISTS idx_error_logs_level ON public.error_logs(level);
CREATE INDEX IF NOT EXISTS idx_error_logs_category ON public.error_logs(category);
CREATE INDEX IF NOT EXISTS idx_error_logs_created_at ON public.error_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_error_logs_resolved ON public.error_logs(resolved);
CREATE INDEX IF NOT EXISTS idx_system_health_logs_timestamp ON public.system_health_logs(timestamp);
CREATE INDEX IF NOT EXISTS idx_health_check_reports_timestamp ON public.health_check_reports(timestamp);
CREATE INDEX IF NOT EXISTS idx_performance_metrics_timestamp ON public.performance_metrics(timestamp);
CREATE INDEX IF NOT EXISTS idx_secure_logs_created_at ON public.secure_logs(created_at);

-- Activer RLS
ALTER TABLE public.error_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_health_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.health_check_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.performance_metrics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.secure_logs ENABLE ROW LEVEL SECURITY;

-- Politiques RLS - Lecture pour admins uniquement
CREATE POLICY "Admins can read error_logs" ON public.error_logs
    FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "System can insert error_logs" ON public.error_logs
    FOR INSERT TO authenticated
    WITH CHECK (true);

CREATE POLICY "Admins can update error_logs" ON public.error_logs
    FOR UPDATE TO authenticated
    USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "Admins can read system_health_logs" ON public.system_health_logs
    FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "System can insert system_health_logs" ON public.system_health_logs
    FOR INSERT TO authenticated
    WITH CHECK (true);

CREATE POLICY "Admins can read health_check_reports" ON public.health_check_reports
    FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "System can insert health_check_reports" ON public.health_check_reports
    FOR INSERT TO authenticated
    WITH CHECK (true);

CREATE POLICY "Admins can read performance_metrics" ON public.performance_metrics
    FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "System can insert performance_metrics" ON public.performance_metrics
    FOR INSERT TO authenticated
    WITH CHECK (true);

CREATE POLICY "Admins can read secure_logs" ON public.secure_logs
    FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "System can insert secure_logs" ON public.secure_logs
    FOR INSERT TO authenticated
    WITH CHECK (true);

-- Fonction RPC pour health check API
CREATE OR REPLACE FUNCTION public.get_system_health_api()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'status', 'healthy',
        'timestamp', now(),
        'database', 'connected'
    ) INTO result;
    
    RETURN result;
END;
$$;

-- Grant execute sur la fonction
GRANT EXECUTE ON FUNCTION public.get_system_health_api() TO authenticated;