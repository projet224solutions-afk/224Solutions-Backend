
-- ============================================
-- MIGRATION DE SÉCURITÉ COMPLÈTE - 224SOLUTIONS
-- (Sans spatial_ref_sys - table système PostGIS)
-- ============================================

-- 1. CORRIGER LES FONCTIONS SANS search_path SÉCURISÉ
-- Fonction update_system_errors_updated_at
CREATE OR REPLACE FUNCTION public.update_system_errors_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- Fonction update_vehicles_updated_at
CREATE OR REPLACE FUNCTION public.update_vehicles_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- 2. CRÉER FONCTION HELPER SÉCURISÉE POUR VÉRIFIER LES RÔLES
CREATE OR REPLACE FUNCTION public.is_authenticated()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT auth.uid() IS NOT NULL;
$$;

-- 3. CORRIGER LES POLICIES ANONYMES CRITIQUES
-- advanced_carts: Restreindre aux utilisateurs authentifiés uniquement
DROP POLICY IF EXISTS "Users manage their cart" ON public.advanced_carts;
CREATE POLICY "Authenticated users manage their cart" ON public.advanced_carts
    FOR ALL TO authenticated
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- 4. FONCTION DE VÉRIFICATION DE SÉCURITÉ
CREATE OR REPLACE FUNCTION public.check_security_status()
RETURNS TABLE(
    tables_with_rls INTEGER,
    tables_without_rls INTEGER,
    secured_functions INTEGER,
    security_score INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_with_rls INTEGER;
    v_without_rls INTEGER;
    v_secured_funcs INTEGER;
    v_score INTEGER;
BEGIN
    -- Compter les tables avec RLS
    SELECT COUNT(*) INTO v_with_rls
    FROM pg_tables t
    JOIN pg_class c ON c.relname = t.tablename
    WHERE t.schemaname = 'public' AND c.relrowsecurity = true;
    
    -- Compter les tables sans RLS
    SELECT COUNT(*) INTO v_without_rls
    FROM pg_tables t
    JOIN pg_class c ON c.relname = t.tablename
    WHERE t.schemaname = 'public' AND c.relrowsecurity = false;
    
    -- Compter les fonctions sécurisées
    SELECT COUNT(*) INTO v_secured_funcs
    FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public' 
    AND p.proconfig IS NOT NULL 
    AND p.proconfig::text LIKE '%search_path%';
    
    -- Calculer le score (sur 100)
    IF (v_with_rls + v_without_rls) > 0 THEN
        v_score := (v_with_rls * 100) / (v_with_rls + v_without_rls);
    ELSE
        v_score := 100;
    END IF;
    
    RETURN QUERY SELECT v_with_rls, v_without_rls, v_secured_funcs, v_score;
END;
$$;

-- 5. FONCTION DE LOG D'AUDIT SÉCURISÉE
CREATE OR REPLACE FUNCTION public.log_security_event(
    p_action TEXT,
    p_target_type TEXT DEFAULT NULL,
    p_target_id TEXT DEFAULT NULL,
    p_data JSONB DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_log_id UUID;
BEGIN
    INSERT INTO public.audit_logs (
        actor_id,
        action,
        target_type,
        target_id,
        data_json,
        created_at
    ) VALUES (
        COALESCE(auth.uid()::TEXT, 'system'),
        p_action,
        p_target_type,
        p_target_id,
        p_data,
        NOW()
    )
    RETURNING id INTO v_log_id;
    
    RETURN v_log_id;
END;
$$;

-- 6. GRANT SÉCURISÉ POUR LES FONCTIONS
GRANT EXECUTE ON FUNCTION public.is_authenticated() TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_security_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_security_event(TEXT, TEXT, TEXT, JSONB) TO authenticated;

-- 7. RÉVOQUER LES ACCÈS PUBLICS DANGEREUX
REVOKE ALL ON FUNCTION public.check_security_status() FROM anon;
REVOKE ALL ON FUNCTION public.log_security_event(TEXT, TEXT, TEXT, JSONB) FROM anon;
