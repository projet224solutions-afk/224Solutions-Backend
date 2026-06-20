-- Supprimer les fonctions existantes
DROP FUNCTION IF EXISTS public.create_syndicate_worker_secure(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB);
DROP FUNCTION IF EXISTS public.update_syndicate_worker_secure(UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, BOOLEAN);
DROP FUNCTION IF EXISTS public.delete_syndicate_worker_secure(UUID, UUID);
DROP FUNCTION IF EXISTS public.toggle_syndicate_worker_status_secure(UUID, UUID, BOOLEAN);

-- Recréer la fonction CREATE avec SET row_security = off
CREATE OR REPLACE FUNCTION public.create_syndicate_worker_secure(
    p_bureau_id UUID,
    p_nom TEXT,
    p_prenom TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL,
    p_telephone TEXT DEFAULT NULL,
    p_access_level TEXT DEFAULT 'member',
    p_permissions JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
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

-- Recréer UPDATE
CREATE OR REPLACE FUNCTION public.update_syndicate_worker_secure(
    p_worker_id UUID,
    p_bureau_id UUID,
    p_nom TEXT DEFAULT NULL,
    p_prenom TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL,
    p_telephone TEXT DEFAULT NULL,
    p_access_level TEXT DEFAULT NULL,
    p_permissions JSONB DEFAULT NULL,
    p_is_active BOOLEAN DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
BEGIN
    UPDATE public.syndicate_workers
    SET
        nom = COALESCE(p_nom, nom),
        prenom = COALESCE(p_prenom, prenom),
        email = COALESCE(p_email, email),
        telephone = COALESCE(p_telephone, telephone),
        access_level = COALESCE(p_access_level, access_level),
        permissions = COALESCE(p_permissions, permissions),
        is_active = COALESCE(p_is_active, is_active),
        updated_at = NOW()
    WHERE id = p_worker_id AND bureau_id = p_bureau_id;
END;
$$;

-- Recréer DELETE
CREATE OR REPLACE FUNCTION public.delete_syndicate_worker_secure(
    p_worker_id UUID,
    p_bureau_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
BEGIN
    DELETE FROM public.syndicate_workers
    WHERE id = p_worker_id AND bureau_id = p_bureau_id;
END;
$$;

-- Recréer TOGGLE STATUS
CREATE OR REPLACE FUNCTION public.toggle_syndicate_worker_status_secure(
    p_worker_id UUID,
    p_bureau_id UUID,
    p_is_active BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
BEGIN
    UPDATE public.syndicate_workers
    SET is_active = p_is_active, updated_at = NOW()
    WHERE id = p_worker_id AND bureau_id = p_bureau_id;
END;
$$;

-- Permissions
GRANT EXECUTE ON FUNCTION public.create_syndicate_worker_secure TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_syndicate_worker_secure TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_syndicate_worker_secure TO authenticated;
GRANT EXECUTE ON FUNCTION public.toggle_syndicate_worker_status_secure TO authenticated;