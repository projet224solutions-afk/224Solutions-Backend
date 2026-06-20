-- Ajouter la colonne prenom si elle n'existe pas
ALTER TABLE public.syndicate_workers 
ADD COLUMN IF NOT EXISTS prenom TEXT;

-- Supprimer les politiques problématiques et créer des politiques simples qui fonctionnent
DROP POLICY IF EXISTS "Bureau can manage workers" ON public.syndicate_workers;
DROP POLICY IF EXISTS "bureau_full_workers_access" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Public can view syndicate_workers with valid bureau" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Public read with valid token" ON public.syndicate_workers;

-- Politique permettant aux utilisateurs authentifiés de lire les workers de leur bureau
CREATE POLICY "Authenticated users can read syndicate workers"
ON public.syndicate_workers
FOR SELECT
TO authenticated
USING (true);

-- Politique permettant aux utilisateurs authentifiés d'insérer des workers
CREATE POLICY "Authenticated users can insert syndicate workers"
ON public.syndicate_workers
FOR INSERT
TO authenticated
WITH CHECK (true);

-- Politique permettant aux utilisateurs authentifiés de mettre à jour des workers
CREATE POLICY "Authenticated users can update syndicate workers"
ON public.syndicate_workers
FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

-- Politique permettant aux utilisateurs authentifiés de supprimer des workers
CREATE POLICY "Authenticated users can delete syndicate workers"
ON public.syndicate_workers
FOR DELETE
TO authenticated
USING (true);

-- Mêmes politiques pour syndicate_worker_permissions
DROP POLICY IF EXISTS "Bureau can manage permissions" ON public.syndicate_worker_permissions;
DROP POLICY IF EXISTS "bureau_full_permissions_access" ON public.syndicate_worker_permissions;

CREATE POLICY "Authenticated users can read permissions"
ON public.syndicate_worker_permissions
FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Authenticated users can insert permissions"
ON public.syndicate_worker_permissions
FOR INSERT
TO authenticated
WITH CHECK (true);

CREATE POLICY "Authenticated users can update permissions"
ON public.syndicate_worker_permissions
FOR UPDATE
TO authenticated
USING (true)
WITH CHECK (true);

CREATE POLICY "Authenticated users can delete permissions"
ON public.syndicate_worker_permissions
FOR DELETE
TO authenticated
USING (true);