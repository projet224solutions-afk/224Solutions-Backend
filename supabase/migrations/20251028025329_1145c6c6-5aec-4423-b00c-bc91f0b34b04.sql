-- Supprimer les anciennes policies si elles existent
DROP POLICY IF EXISTS "Agents can create sub-agents" ON agents_management;
DROP POLICY IF EXISTS "Agents can view their sub-agents" ON agents_management;
DROP POLICY IF EXISTS "Agents can update their own profile" ON agents_management;

-- Créer les nouvelles policies
CREATE POLICY "Agents can create sub-agents"
ON agents_management
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM agents_management parent
    WHERE parent.user_id = auth.uid()
    AND parent.is_active = true
    AND (parent.can_create_sub_agent = true OR parent.permissions @> '["create_sub_agents"]'::jsonb)
  )
);

-- Permettre aux agents de voir leurs sous-agents
CREATE POLICY "Agents can view their sub-agents"
ON agents_management
FOR SELECT
TO authenticated
USING (
  user_id = auth.uid()
  OR
  EXISTS (
    SELECT 1 FROM agents_management parent
    WHERE parent.user_id = auth.uid()
    AND parent.pdg_id = agents_management.pdg_id
    AND parent.is_active = true
  )
);

-- Permettre aux agents de mettre à jour leurs propres infos
CREATE POLICY "Agents can update their own profile"
ON agents_management
FOR UPDATE
TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());