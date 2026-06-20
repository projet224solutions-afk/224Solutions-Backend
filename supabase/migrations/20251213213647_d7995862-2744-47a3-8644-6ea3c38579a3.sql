
-- =====================================================
-- SYSTÈME DE PERMISSIONS MEMBRES BUREAU SYNDICAT
-- Similaire au système des agents vendeur
-- =====================================================

-- 1. Table des permissions des membres du bureau syndicat
CREATE TABLE IF NOT EXISTS public.syndicate_worker_permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    worker_id UUID NOT NULL REFERENCES public.syndicate_workers(id) ON DELETE CASCADE,
    permission_key VARCHAR(100) NOT NULL,
    permission_value BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(worker_id, permission_key)
);

-- 2. Enable RLS
ALTER TABLE public.syndicate_worker_permissions ENABLE ROW LEVEL SECURITY;

-- 3. RLS Policies
CREATE POLICY "Bureaus can manage their worker permissions"
ON public.syndicate_worker_permissions
FOR ALL
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM syndicate_workers sw
        JOIN bureaus b ON sw.bureau_id = b.id
        WHERE sw.id = syndicate_worker_permissions.worker_id
        AND b.id IN (
            SELECT id FROM bureaus WHERE president_email = auth.email()
            UNION
            SELECT bureau_id FROM syndicate_workers WHERE email = auth.email() AND access_level = 'president'
        )
    )
);

CREATE POLICY "PDG can view all worker permissions"
ON public.syndicate_worker_permissions
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
    )
);

CREATE POLICY "Workers can view their own permissions"
ON public.syndicate_worker_permissions
FOR SELECT
TO authenticated
USING (
    worker_id IN (
        SELECT id FROM syndicate_workers WHERE email = auth.email()
    )
);

-- 4. Fonction pour obtenir les permissions d'un membre
CREATE OR REPLACE FUNCTION public.get_syndicate_worker_permissions(p_worker_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    result JSONB := '{}';
BEGIN
    SELECT jsonb_object_agg(permission_key, permission_value)
    INTO result
    FROM syndicate_worker_permissions
    WHERE worker_id = p_worker_id;
    
    RETURN COALESCE(result, '{}');
END;
$$;

-- 5. Fonction pour définir les permissions d'un membre
CREATE OR REPLACE FUNCTION public.set_syndicate_worker_permissions(
    p_worker_id UUID,
    p_permissions JSONB
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    key TEXT;
    value BOOLEAN;
BEGIN
    -- Vérifier que le worker existe
    IF NOT EXISTS (SELECT 1 FROM syndicate_workers WHERE id = p_worker_id) THEN
        RAISE EXCEPTION 'Worker not found';
    END IF;
    
    -- Supprimer les anciennes permissions
    DELETE FROM syndicate_worker_permissions WHERE worker_id = p_worker_id;
    
    -- Insérer les nouvelles permissions
    FOR key, value IN SELECT * FROM jsonb_each(p_permissions)
    LOOP
        INSERT INTO syndicate_worker_permissions (worker_id, permission_key, permission_value)
        VALUES (p_worker_id, key, value::BOOLEAN)
        ON CONFLICT (worker_id, permission_key) 
        DO UPDATE SET permission_value = value::BOOLEAN, updated_at = now();
    END LOOP;
    
    RETURN TRUE;
END;
$$;

-- 6. Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_syndicate_worker_permissions_timestamp()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_syndicate_worker_permissions_timestamp ON syndicate_worker_permissions;
CREATE TRIGGER trigger_update_syndicate_worker_permissions_timestamp
    BEFORE UPDATE ON syndicate_worker_permissions
    FOR EACH ROW
    EXECUTE FUNCTION update_syndicate_worker_permissions_timestamp();

-- 7. Index pour performance
CREATE INDEX IF NOT EXISTS idx_syndicate_worker_permissions_worker_id 
ON syndicate_worker_permissions(worker_id);

-- 8. Ajouter des colonnes utiles à syndicate_workers si elles n'existent pas
ALTER TABLE syndicate_workers ADD COLUMN IF NOT EXISTS access_level VARCHAR(50) DEFAULT 'member';
ALTER TABLE syndicate_workers ADD COLUMN IF NOT EXISTS commission_rate NUMERIC(5,2) DEFAULT 0;
ALTER TABLE syndicate_workers ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMPTZ;
ALTER TABLE syndicate_workers ADD COLUMN IF NOT EXISTS login_attempts INTEGER DEFAULT 0;
ALTER TABLE syndicate_workers ADD COLUMN IF NOT EXISTS locked_until TIMESTAMPTZ;

-- 9. Grant permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON syndicate_worker_permissions TO authenticated;
GRANT EXECUTE ON FUNCTION get_syndicate_worker_permissions(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION set_syndicate_worker_permissions(UUID, JSONB) TO authenticated;
