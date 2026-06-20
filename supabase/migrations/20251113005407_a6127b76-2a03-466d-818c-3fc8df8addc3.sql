-- Ajouter le type d'agent à la table vendor_agents

-- Créer l'énumération pour les types d'agents
CREATE TYPE public.agent_type_enum AS ENUM (
  'commercial',
  'logistique',
  'support',
  'administratif',
  'manager',
  'technique'
);

-- Ajouter la colonne agent_type à la table vendor_agents
ALTER TABLE public.vendor_agents
ADD COLUMN agent_type public.agent_type_enum DEFAULT 'commercial';

-- Créer un index sur agent_type pour améliorer les performances des requêtes filtrées
CREATE INDEX IF NOT EXISTS idx_vendor_agents_agent_type ON public.vendor_agents(agent_type);

-- Commenter la colonne pour la documentation
COMMENT ON COLUMN public.vendor_agents.agent_type IS 'Type d''agent: commercial, logistique, support, administratif, manager, technique';