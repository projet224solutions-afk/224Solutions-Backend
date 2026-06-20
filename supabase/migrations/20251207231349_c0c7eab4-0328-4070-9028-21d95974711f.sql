-- ========================================
-- SÉCURITÉ NIVEAU 2: Correction search_path des fonctions
-- ========================================

-- Correction automatique de TOUTES les fonctions sans search_path
DO $$
DECLARE
    func_record RECORD;
    func_signature TEXT;
    fixed_count INTEGER := 0;
BEGIN
    -- Parcourir toutes les fonctions du schéma public qui n'ont pas de search_path fixé
    FOR func_record IN 
        SELECT 
            p.proname as function_name,
            pg_get_function_identity_arguments(p.oid) as args,
            p.oid
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
        AND p.prokind = 'f'
        AND (p.proconfig IS NULL OR NOT EXISTS (
            SELECT 1 FROM unnest(p.proconfig) AS conf 
            WHERE conf LIKE 'search_path=%'
        ))
    LOOP
        BEGIN
            -- Construire la signature complète
            func_signature := 'public.' || quote_ident(func_record.function_name) || '(' || func_record.args || ')';
            
            -- Appliquer SET search_path = public
            EXECUTE 'ALTER FUNCTION ' || func_signature || ' SET search_path = public';
            
            fixed_count := fixed_count + 1;
            RAISE NOTICE 'Fixed search_path for: %', func_signature;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Skipped (error): % - %', func_record.function_name, SQLERRM;
        END;
    END LOOP;
    
    RAISE NOTICE 'Total functions fixed: %', fixed_count;
END $$;

-- ========================================
-- Audit log de la correction de sécurité
-- ========================================
INSERT INTO public.security_audit_logs (
    action,
    actor_type,
    target_type,
    details,
    created_at
) 
SELECT
    'security_hardening_phase2',
    'system',
    'database_functions',
    jsonb_build_object(
        'operation', 'fix_search_path',
        'description', 'Correction des search_path pour toutes les fonctions publiques',
        'timestamp', now()
    ),
    now()
WHERE EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'security_audit_logs');