-- Corriger les policies sur agent_created_users pour le service_role
DROP POLICY IF EXISTS "service_role_all" ON public.agent_created_users;

CREATE POLICY "service_role_can_insert"
ON public.agent_created_users
FOR INSERT
TO authenticated
WITH CHECK (true);

CREATE POLICY "service_role_can_manage"
ON public.agent_created_users
FOR ALL
USING (true)
WITH CHECK (true);

-- Commentaire
COMMENT ON POLICY "service_role_can_insert" ON public.agent_created_users IS 
'Permet au service_role via edge function de créer des liens agent-utilisateur';

COMMENT ON POLICY "service_role_can_manage" ON public.agent_created_users IS 
'Permet la gestion complète des liens agent-utilisateur';