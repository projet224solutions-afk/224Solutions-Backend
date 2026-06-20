-- Créer la table pdg_management pour stocker les profils PDG
CREATE TABLE IF NOT EXISTS public.pdg_management (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name VARCHAR(255) NOT NULL,
  email VARCHAR(255) NOT NULL,
  phone VARCHAR(50),
  permissions JSONB DEFAULT '[]'::JSONB,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE(user_id)
);

-- Créer la table agents_management pour les agents gérés par le PDG
CREATE TABLE IF NOT EXISTS public.agents_management (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pdg_id UUID NOT NULL REFERENCES public.pdg_management(id) ON DELETE CASCADE,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  agent_code VARCHAR(50) UNIQUE NOT NULL,
  name VARCHAR(255) NOT NULL,
  email VARCHAR(255) NOT NULL,
  phone VARCHAR(50),
  role VARCHAR(100),
  permissions JSONB DEFAULT '[]'::JSONB,
  commission_rate NUMERIC(5,2) DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Activer RLS
ALTER TABLE public.pdg_management ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agents_management ENABLE ROW LEVEL SECURITY;

-- Politiques RLS pour pdg_management
CREATE POLICY "PDG can manage their own profile"
  ON public.pdg_management
  FOR ALL
  USING (auth.uid() = user_id);

CREATE POLICY "Admins can view all PDG profiles"
  ON public.pdg_management
  FOR SELECT
  USING (has_role(auth.uid(), 'admin'::user_role));

-- Politiques RLS pour agents_management
CREATE POLICY "PDG can manage their agents"
  ON public.agents_management
  FOR ALL
  USING (EXISTS (
    SELECT 1 FROM public.pdg_management
    WHERE id = agents_management.pdg_id
    AND user_id = auth.uid()
  ));

CREATE POLICY "Agents can view their own profile"
  ON public.agents_management
  FOR SELECT
  USING (user_id = auth.uid());

-- Trigger pour updated_at
CREATE TRIGGER update_pdg_management_updated_at
  BEFORE UPDATE ON public.pdg_management
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_agents_management_updated_at
  BEFORE UPDATE ON public.agents_management
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- Index pour améliorer les performances
CREATE INDEX idx_pdg_management_user_id ON public.pdg_management(user_id);
CREATE INDEX idx_agents_management_pdg_id ON public.agents_management(pdg_id);
CREATE INDEX idx_agents_management_user_id ON public.agents_management(user_id);
CREATE INDEX idx_agents_management_agent_code ON public.agents_management(agent_code);