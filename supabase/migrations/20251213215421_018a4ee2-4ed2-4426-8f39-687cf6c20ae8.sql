-- Supprimer TOUTES les politiques existantes sur syndicate_workers
DROP POLICY IF EXISTS "Admins can delete workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Admins can manage all workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Authenticated users can insert syndicate workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Authenticated users can read syndicate workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Bureau presidents can manage their workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "PDG and Admins manage workers v2" ON public.syndicate_workers;
DROP POLICY IF EXISTS "PDG and Admins view all workers v2" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Workers can view their own data" ON public.syndicate_workers;
DROP POLICY IF EXISTS "service_role_all" ON public.syndicate_workers;
DROP POLICY IF EXISTS "syndicate_workers_delete_policy" ON public.syndicate_workers;
DROP POLICY IF EXISTS "syndicate_workers_insert_policy" ON public.syndicate_workers;
DROP POLICY IF EXISTS "syndicate_workers_select_policy" ON public.syndicate_workers;
DROP POLICY IF EXISTS "syndicate_workers_update_policy" ON public.syndicate_workers;

-- Créer une seule politique simple pour tout
CREATE POLICY "allow_all_authenticated" 
ON public.syndicate_workers 
FOR ALL 
TO authenticated
USING (true)
WITH CHECK (true);

-- Même chose pour syndicate_worker_permissions
DROP POLICY IF EXISTS "Authenticated users can delete permissions" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "Authenticated users can read permissions" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "Authenticated users can update permissions" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "Bureaus can manage their worker permissions" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "PDG can view all worker permissions" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "Workers can view their own permissions" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "worker_permissions_delete_policy" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "worker_permissions_insert_policy" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "worker_permissions_select_policy" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "worker_permissions_update_policy" ON public.syndicate_worker_permissions;

CREATE POLICY "allow_all_authenticated" 
ON public.syndicate_worker_permissions 
FOR ALL 
TO authenticated
USING (true)
WITH CHECK (true);