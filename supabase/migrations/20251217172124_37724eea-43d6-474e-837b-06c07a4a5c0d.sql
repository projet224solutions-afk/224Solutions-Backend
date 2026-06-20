-- Fix create_syndicate_worker_secure to properly bypass RLS
DROP FUNCTION IF EXISTS public.create_syndicate_worker_secure(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB);

CREATE OR REPLACE FUNCTION public.create_syndicate_worker_secure(
    p_bureau_id UUID,
    p_nom TEXT,
    p_prenom TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL,
    p_telephone TEXT DEFAULT NULL,
    p_access_level TEXT DEFAULT 'member',
    p_permissions JSONB DEFAULT '{}'::JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET row_security = off
SET search_path = public
AS $$
DECLARE
    v_worker_id UUID;
    v_unique_token TEXT;
    v_custom_id TEXT;
    v_counter INT;
BEGIN
    v_unique_token := 'sw_' || encode(gen_random_bytes(16), 'hex');
    
    SELECT COALESCE(MAX(CAST(SUBSTRING(custom_id FROM 4) AS INTEGER)), 0) + 1
    INTO v_counter
    FROM public.syndicate_workers
    WHERE custom_id LIKE 'MBR%';
    
    v_custom_id := 'MBR' || LPAD(v_counter::TEXT, 4, '0');
    
    INSERT INTO public.syndicate_workers (
        bureau_id, custom_id, nom, prenom, email, telephone,
        access_level, permissions, access_token, is_active
    ) VALUES (
        p_bureau_id, v_custom_id, p_nom, p_prenom,
        COALESCE(p_email, 'worker_' || encode(gen_random_bytes(8), 'hex') || '@bureau.local'),
        p_telephone, COALESCE(p_access_level, 'member'),
        COALESCE(p_permissions, '{}'::jsonb), v_unique_token, true
    )
    RETURNING id INTO v_worker_id;
    
    RETURN v_worker_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_syndicate_worker_secure TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_syndicate_worker_secure TO anon;