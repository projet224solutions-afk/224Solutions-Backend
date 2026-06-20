-- Supprimer toutes les policies existantes sur agent_created_users
DROP POLICY IF EXISTS "service_role_can_insert" ON public.agent_created_users;
DROP POLICY IF EXISTS "service_role_can_manage" ON public.agent_created_users;
DROP POLICY IF EXISTS "service_role_all" ON public.agent_created_users;
DROP POLICY IF EXISTS "Agents can view their created users" ON public.agent_created_users;

-- Recréer les policies correctement
CREATE POLICY "agents_view_created_users"
ON public.agent_created_users
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM agents_management
    WHERE agents_management.id = agent_created_users.agent_id
    AND agents_management.user_id = auth.uid()
  )
);

CREATE POLICY "allow_insert_agent_users"
ON public.agent_created_users
FOR INSERT
TO authenticated
WITH CHECK (true);

-- Commentaire
COMMENT ON TABLE public.agent_created_users IS 'Liens entre agents et utilisateurs créés - policies RLS mises à jour';