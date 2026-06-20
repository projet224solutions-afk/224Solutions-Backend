-- Supprimer toutes les anciennes politiques RLS sur syndicate_workers
DROP POLICY IF EXISTS "Authenticated users can view syndicate workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Authenticated users can create syndicate workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Authenticated users can update syndicate workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Authenticated users can delete syndicate workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Allow authenticated select" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Allow authenticated insert" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Allow authenticated update" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Allow authenticated delete" ON public.syndicate_workers;

-- Créer des politiques simples et permissives pour les utilisateurs authentifiés
CREATE POLICY "syndicate_workers_select_policy" 
ON public.syndicate_workers 
FOR SELECT 
TO authenticated
USING (true);

CREATE POLICY "syndicate_workers_insert_policy" 
ON public.syndicate_workers 
FOR INSERT 
TO authenticated
WITH CHECK (true);

CREATE POLICY "syndicate_workers_update_policy" 
ON public.syndicate_workers 
FOR UPDATE 
TO authenticated
USING (true)
WITH CHECK (true);

CREATE POLICY "syndicate_workers_delete_policy" 
ON public.syndicate_workers 
FOR DELETE 
TO authenticated
USING (true);

-- Même chose pour syndicate_worker_permissions
DROP POLICY IF EXISTS "Authenticated users can view permissions" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "Authenticated users can manage permissions" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "Allow authenticated select permissions" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "Allow authenticated insert permissions" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "Allow authenticated update permissions" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "Allow authenticated delete permissions" ON public.syndicate_worker_permissions;

CREATE POLICY "worker_permissions_select_policy" 
ON public.syndicate_worker_permissions 
FOR SELECT 
TO authenticated
USING (true);

CREATE POLICY "worker_permissions_insert_policy" 
ON public.syndicate_worker_permissions 
FOR INSERT 
TO authenticated
WITH CHECK (true);

CREATE POLICY "worker_permissions_update_policy" 
ON public.syndicate_worker_permissions 
FOR UPDATE 
TO authenticated
USING (true)
WITH CHECK (true);

CREATE POLICY "worker_permissions_delete_policy" 
ON public.syndicate_worker_permissions 
FOR DELETE 
TO authenticated
USING (true);