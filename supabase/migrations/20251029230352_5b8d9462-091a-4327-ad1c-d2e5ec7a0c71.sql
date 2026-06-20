-- Policy pour permettre aux PDG de créer des agents dans leur organisation
CREATE POLICY "pdg_can_create_agents"
ON public.agents_management
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.pdg_management
    WHERE pdg_management.id = agents_management.pdg_id
    AND pdg_management.user_id = auth.uid()
  )
);

-- Policy pour permettre aux utilisateurs de créer leur premier agent (devenir agent)
CREATE POLICY "users_can_create_their_agent_profile"
ON public.agents_management
FOR INSERT
TO authenticated
WITH CHECK (user_id = auth.uid());