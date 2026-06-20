-- Table pour les invitations d'agents
CREATE TABLE IF NOT EXISTS public.agent_invitations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id UUID NOT NULL REFERENCES public.agents_management(id) ON DELETE CASCADE,
  pdg_id UUID NOT NULL REFERENCES public.pdg_management(id) ON DELETE CASCADE,
  invitation_token TEXT NOT NULL UNIQUE,
  email TEXT NOT NULL,
  phone TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'expired')),
  sent_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  accepted_at TIMESTAMP WITH TIME ZONE,
  expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Index pour recherche rapide par token
CREATE INDEX IF NOT EXISTS idx_agent_invitations_token ON public.agent_invitations(invitation_token);
CREATE INDEX IF NOT EXISTS idx_agent_invitations_agent ON public.agent_invitations(agent_id);

-- Enable RLS
ALTER TABLE public.agent_invitations ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "PDG can manage their agent invitations"
ON public.agent_invitations
FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM public.pdg_management
    WHERE pdg_management.id = agent_invitations.pdg_id
    AND pdg_management.user_id = auth.uid()
  )
);

CREATE POLICY "Agents can view their own invitations"
ON public.agent_invitations
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.agents_management
    WHERE agents_management.id = agent_invitations.agent_id
    AND agents_management.email = (auth.jwt() ->> 'email')
  )
);

CREATE POLICY "service_role_all_agent_invitations"
ON public.agent_invitations
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- Fonction pour générer un token unique d'invitation
CREATE OR REPLACE FUNCTION public.generate_invitation_token()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  new_token TEXT;
BEGIN
  new_token := encode(gen_random_bytes(32), 'base64');
  new_token := replace(replace(replace(new_token, '/', '_'), '+', '-'), '=', '');
  
  WHILE EXISTS (SELECT 1 FROM public.agent_invitations WHERE invitation_token = new_token) LOOP
    new_token := encode(gen_random_bytes(32), 'base64');
    new_token := replace(replace(replace(new_token, '/', '_'), '+', '-'), '=', '');
  END LOOP;
  
  RETURN new_token;
END;
$$;