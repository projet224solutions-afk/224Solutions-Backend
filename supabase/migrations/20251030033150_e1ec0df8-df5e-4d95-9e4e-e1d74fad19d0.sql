-- Ajouter une policy pour permettre au PDG de voir tous les agent_created_users
CREATE POLICY "PDG can view all agent_created_users"
ON agent_created_users
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM agents_management
    WHERE agents_management.id = agent_created_users.agent_id
    AND EXISTS (
      SELECT 1 FROM pdg_management
      WHERE pdg_management.id = agents_management.pdg_id
      AND pdg_management.user_id = auth.uid()
    )
  )
);