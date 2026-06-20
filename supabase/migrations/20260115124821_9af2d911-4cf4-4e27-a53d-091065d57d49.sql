-- =====================================================
-- PHASE 1: FIX SECURITY DEFINER VIEWS + 2FA INFRASTRUCTURE
-- =====================================================

-- Create security_events table if not exists
CREATE TABLE IF NOT EXISTS public.security_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type TEXT NOT NULL,
    severity_level TEXT NOT NULL DEFAULT 'info',
    user_id UUID,
    ip_address INET,
    details JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.security_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins can view security events" ON public.security_events FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- 1. Recreate security_policy_summary view
DROP VIEW IF EXISTS public.security_policy_summary CASCADE;
CREATE VIEW public.security_policy_summary WITH (security_invoker = on) AS
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check FROM pg_policies WHERE schemaname = 'public';

-- 2. Recreate interface_status view
DROP VIEW IF EXISTS public.interface_status CASCADE;
CREATE VIEW public.interface_status WITH (security_invoker = on) AS
SELECT 'bureaus' as entity_type, id, bureau_code as code, status, interface_url, last_activity, created_at FROM bureaus
UNION ALL
SELECT 'agents' as entity_type, id, agent_code as code, CASE WHEN is_active THEN 'active' ELSE 'inactive' END as status, NULL as interface_url, last_login_at as last_activity, created_at FROM agents_management;

-- 3. Recreate pdg_interface_stats view
DROP VIEW IF EXISTS public.pdg_interface_stats CASCADE;
CREATE VIEW public.pdg_interface_stats WITH (security_invoker = on) AS
SELECT p.id as pdg_id, p.name as pdg_name, COUNT(DISTINCT a.id) as total_agents, COUNT(DISTINCT CASE WHEN a.is_active THEN a.id END) as active_agents, SUM(COALESCE(aw.balance, 0)) as total_wallet_balance, MAX(a.last_login_at) as last_agent_activity
FROM pdg_management p LEFT JOIN agents_management a ON a.pdg_id = p.id LEFT JOIN agent_wallets aw ON aw.agent_id = a.id GROUP BY p.id, p.name;

-- 4. Recreate pdg_vehicle_security_overview view
DROP VIEW IF EXISTS public.pdg_vehicle_security_overview CASCADE;
CREATE VIEW public.pdg_vehicle_security_overview WITH (security_invoker = on) AS
SELECT p.id as pdg_id, p.name as pdg_name, COUNT(DISTINCT v.id) as total_vehicles, COUNT(DISTINCT CASE WHEN v.status = 'active' THEN v.id END) as active_vehicles, COUNT(DISTINCT CASE WHEN v.is_stolen THEN v.id END) as stolen_vehicles
FROM pdg_management p LEFT JOIN bureaus b ON b.user_id = p.user_id LEFT JOIN vehicles v ON v.bureau_id = b.id GROUP BY p.id, p.name;

-- 5. Recreate security_stats view
DROP VIEW IF EXISTS public.security_stats CASCADE;
CREATE VIEW public.security_stats WITH (security_invoker = on) AS
SELECT (SELECT COUNT(*) FROM security_events WHERE created_at > NOW() - INTERVAL '24 hours') as events_24h, (SELECT COUNT(*) FROM security_events WHERE severity_level = 'critical' AND created_at > NOW() - INTERVAL '24 hours') as critical_24h, (SELECT COUNT(*) FROM blocked_ips WHERE is_active = true) as active_blocks, (SELECT COUNT(*) FROM security_incidents WHERE status = 'open') as open_incidents;

-- 6. Recreate system_alerts_summary view
DROP VIEW IF EXISTS public.system_alerts_summary CASCADE;
CREATE VIEW public.system_alerts_summary WITH (security_invoker = on) AS
SELECT priority, COUNT(*) as count, COUNT(*) FILTER (WHERE is_read = false) as unread_count FROM admin_notifications WHERE created_at > NOW() - INTERVAL '7 days' GROUP BY priority;

-- =====================================================
-- PHASE 2: 2FA/TOTP INFRASTRUCTURE
-- =====================================================

CREATE TABLE IF NOT EXISTS public.user_2fa_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL UNIQUE,
    is_enabled BOOLEAN DEFAULT false,
    totp_secret_encrypted TEXT,
    totp_secret_iv TEXT,
    backup_codes_encrypted TEXT,
    backup_codes_iv TEXT,
    last_used_at TIMESTAMPTZ,
    verified_at TIMESTAMPTZ,
    recovery_email TEXT,
    preferred_method TEXT DEFAULT 'totp' CHECK (preferred_method IN ('totp', 'sms', 'email')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.user_2fa_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage 2FA" ON public.user_2fa_settings FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

CREATE TABLE IF NOT EXISTS public.totp_verification_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    ip_address INET,
    user_agent TEXT,
    success BOOLEAN NOT NULL,
    failure_reason TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.totp_verification_attempts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own attempts" ON public.totp_verification_attempts FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE INDEX IF NOT EXISTS idx_totp_attempts ON public.totp_verification_attempts(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_security_events_created ON public.security_events(created_at DESC);

-- Function to check 2FA status
CREATE OR REPLACE FUNCTION public.check_2fa_status(p_user_id UUID)
RETURNS TABLE(is_enabled BOOLEAN, preferred_method TEXT, last_used_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN QUERY SELECT u2fa.is_enabled, u2fa.preferred_method, u2fa.last_used_at FROM user_2fa_settings u2fa WHERE u2fa.user_id = p_user_id;
END;
$$;

GRANT SELECT, INSERT, UPDATE ON public.user_2fa_settings TO authenticated;
GRANT SELECT, INSERT ON public.totp_verification_attempts TO authenticated;
GRANT SELECT ON public.security_events TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_2fa_status TO authenticated;