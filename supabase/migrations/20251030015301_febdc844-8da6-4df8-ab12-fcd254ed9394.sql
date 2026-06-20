-- Ajouter la colonne parent_agent_id à la table agents_management
ALTER TABLE public.agents_management
ADD COLUMN IF NOT EXISTS parent_agent_id UUID REFERENCES public.agents_management(id) ON DELETE SET NULL;

-- Créer un index pour optimiser les requêtes
CREATE INDEX IF NOT EXISTS idx_agents_parent_agent_id ON public.agents_management(parent_agent_id);

-- Commentaire
COMMENT ON COLUMN public.agents_management.parent_agent_id IS 'ID de l''agent parent pour les sous-agents. NULL pour les agents directs du PDG';