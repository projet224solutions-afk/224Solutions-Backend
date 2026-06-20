-- Ajouter la colonne agent_type à la table agents_management
ALTER TABLE public.agents_management
ADD COLUMN IF NOT EXISTS agent_type TEXT DEFAULT 'sales' CHECK (agent_type IN ('sales', 'support', 'manager', 'delivery', 'admin'));

-- Ajouter un commentaire pour documenter la colonne
COMMENT ON COLUMN public.agents_management.agent_type IS 'Type d''agent: sales (Commercial), support (Support Client), manager (Manager), delivery (Livraison), admin (Administrateur)';

-- Mettre à jour les agents existants avec un type par défaut
UPDATE public.agents_management
SET agent_type = 'sales'
WHERE agent_type IS NULL;

-- Ajouter les colonnes agent_code et agent_type à la table profiles
ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS agent_code TEXT,
ADD COLUMN IF NOT EXISTS agent_type TEXT CHECK (agent_type IN ('sales', 'support', 'manager', 'delivery', 'admin'));

-- Ajouter un commentaire pour documenter les colonnes
COMMENT ON COLUMN public.profiles.agent_code IS 'Code unique de l''agent (si le profil est un agent)';
COMMENT ON COLUMN public.profiles.agent_type IS 'Type d''agent (si le profil est un agent): sales, support, manager, delivery, admin';
