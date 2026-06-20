-- Permettre aux agents de voir les utilisateurs créés par leurs sous-agents
CREATE POLICY "Agents can view sub-agents created users"
ON agent_created_users
FOR SELECT
USING (
  -- L'agent peut voir ses propres utilisateurs créés
  agent_id IN (
    SELECT id FROM agents_management 
    WHERE user_id = auth.uid()
  )
  OR
  -- L'agent peut voir les utilisateurs créés par ses sous-agents
  agent_id IN (
    SELECT sa.id 
    FROM agents_management sa
    INNER JOIN agents_management parent ON sa.parent_agent_id = parent.id
    WHERE parent.user_id = auth.uid()
  )
);