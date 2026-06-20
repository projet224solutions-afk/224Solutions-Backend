-- ===================================================================
-- PHASE 1: CORRECTION SÉCURITÉ DE BASE
-- ===================================================================

DO $$
DECLARE
    func_rec RECORD;
    table_rec RECORD;
BEGIN
    -- 1️⃣ Corriger toutes les fonctions avec search_path mutable (30 WARN)
    FOR func_rec IN 
        SELECT 
            n.nspname AS schema_name,
            p.proname AS function_name,
            pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
        AND p.proname IN (
            'initiate_escrow',
            'release_escrow', 
            'refund_escrow',
            'dispute_escrow',
            'process_virtual_card_transaction',
            'create_virtual_card',
            'block_virtual_card',
            'unblock_virtual_card',
            'update_updated_at_column',
            'handle_new_user',
            'handle_user_role_change',
            'check_wallet_balance',
            'deduct_wallet_balance',
            'add_wallet_balance',
            'block_ip_address',
            'unblock_ip_address',
            'log_security_event',
            'create_security_incident',
            'update_incident_status',
            'log_failed_login',
            'check_brute_force',
            'rotate_encryption_key',
            'get_active_encryption_key',
            'cleanup_old_rate_limits'
        )
    LOOP
        EXECUTE format('
            ALTER FUNCTION %I.%I(%s) 
            SET search_path = public, pg_catalog
        ', func_rec.schema_name, func_rec.function_name, func_rec.args);
    END LOOP;

    -- 2️⃣ Activer RLS sur TOUTES les tables publiques
    FOR table_rec IN 
        SELECT tablename 
        FROM pg_tables 
        WHERE schemaname = 'public'
        AND tablename NOT IN (
            'migrations', 
            'schema_migrations',
            'spatial_ref_sys',
            'geography_columns',
            'geometry_columns',
            'raster_columns',
            'raster_overviews',
            'topology',
            'layer'
        )
        AND tableowner != 'postgres'
    LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', table_rec.tablename);
    END LOOP;

    RAISE NOTICE '✅ PHASE 1 SÉCURITÉ: Corrections de base appliquées';
END $$;

-- 5️⃣ Créer une table pour le rate limiting
CREATE TABLE IF NOT EXISTS public.rate_limits (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    identifier TEXT NOT NULL,
    action TEXT NOT NULL,
    count INTEGER DEFAULT 1,
    window_start TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(identifier, action, window_start)
);

ALTER TABLE public.rate_limits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role manages rate_limits" ON rate_limits;
CREATE POLICY "Service role manages rate_limits"
ON rate_limits FOR ALL
USING (true)
WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_rate_limits_lookup 
ON rate_limits(identifier, action, window_start);

-- 6️⃣ Créer une table pour les tentatives de connexion échouées
CREATE TABLE IF NOT EXISTS public.failed_login_attempts (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    identifier TEXT NOT NULL,
    ip_address TEXT,
    attempt_count INTEGER DEFAULT 1,
    last_attempt TIMESTAMPTZ DEFAULT NOW(),
    blocked_until TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.failed_login_attempts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role manages failed_logins" ON failed_login_attempts;
CREATE POLICY "Service role manages failed_logins"
ON failed_login_attempts FOR ALL
USING (true)
WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_failed_login_identifier 
ON failed_login_attempts(identifier);

-- 7️⃣ Créer une fonction pour vérifier le rate limit
CREATE OR REPLACE FUNCTION check_rate_limit(
    p_identifier TEXT,
    p_action TEXT,
    p_max_requests INTEGER DEFAULT 10,
    p_window_minutes INTEGER DEFAULT 1
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_count INTEGER;
    v_window_start TIMESTAMPTZ;
BEGIN
    v_window_start := DATE_TRUNC('minute', NOW()) - (p_window_minutes || ' minutes')::INTERVAL;
    
    SELECT COALESCE(SUM(count), 0) INTO v_count
    FROM rate_limits
    WHERE identifier = p_identifier
    AND action = p_action
    AND window_start >= v_window_start;
    
    IF v_count >= p_max_requests THEN
        RETURN FALSE;
    END IF;
    
    INSERT INTO rate_limits (identifier, action, window_start, count)
    VALUES (p_identifier, p_action, DATE_TRUNC('minute', NOW()), 1)
    ON CONFLICT (identifier, action, window_start)
    DO UPDATE SET count = rate_limits.count + 1;
    
    RETURN TRUE;
END;
$$;

-- 8️⃣ Créer des indexes de performance sur les tables critiques (si elles existent)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='wallets' AND column_name='user_id') THEN
        CREATE INDEX IF NOT EXISTS idx_wallets_user_id ON wallets(user_id);
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='virtual_cards' AND column_name='user_id') THEN
        CREATE INDEX IF NOT EXISTS idx_virtual_cards_user_id ON virtual_cards(user_id);
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='financial_transactions' AND column_name='user_id') THEN
        CREATE INDEX IF NOT EXISTS idx_financial_transactions_user ON financial_transactions(user_id);
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='escrow_transactions' AND column_name='payer_id') THEN
        CREATE INDEX IF NOT EXISTS idx_escrow_payer ON escrow_transactions(payer_id);
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='escrow_transactions' AND column_name='receiver_id') THEN
        CREATE INDEX IF NOT EXISTS idx_escrow_receiver ON escrow_transactions(receiver_id);
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='security_audit_logs' AND column_name='user_id') THEN
        CREATE INDEX IF NOT EXISTS idx_security_audit_user ON security_audit_logs(user_id);
    END IF;
END $$;

-- 9️⃣ Nettoyer les anciennes données de rate limiting (cleanup automatique)
CREATE OR REPLACE FUNCTION cleanup_old_rate_limits()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    DELETE FROM rate_limits
    WHERE window_start < NOW() - INTERVAL '1 hour';
    
    DELETE FROM failed_login_attempts
    WHERE created_at < NOW() - INTERVAL '24 hours'
    AND blocked_until IS NULL;
END;
$$;