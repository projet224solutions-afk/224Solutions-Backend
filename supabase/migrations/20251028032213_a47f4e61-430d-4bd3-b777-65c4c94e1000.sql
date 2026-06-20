-- Table pour tracker les utilisateurs créés par les agents
CREATE TABLE IF NOT EXISTS public.agent_created_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id UUID NOT NULL REFERENCES public.agents_management(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  user_role TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE(agent_id, user_id)
);

-- Index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_agent_created_users_agent_id ON public.agent_created_users(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_created_users_user_id ON public.agent_created_users(user_id);

-- Enable RLS
ALTER TABLE public.agent_created_users ENABLE ROW LEVEL SECURITY;

-- Policy: Les agents peuvent voir leurs utilisateurs créés
CREATE POLICY "Agents can view their created users"
ON public.agent_created_users FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.agents_management
    WHERE agents_management.id = agent_created_users.agent_id
      AND agents_management.user_id = auth.uid()
  )
);

-- Policy: Service role peut tout faire
CREATE POLICY "service_role_all"
ON public.agent_created_users FOR ALL TO service_role
USING (true)
WITH CHECK (true);