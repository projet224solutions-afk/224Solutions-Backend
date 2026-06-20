-- Ajouter la colonne type_agent à agents_management si elle n'existe pas
-- La contrainte CHECK dans 20251202101502 référence cette colonne sans l'avoir créée
ALTER TABLE public.agents_management
ADD COLUMN IF NOT EXISTS type_agent TEXT DEFAULT 'principal';

-- Mettre à jour les agents existants sans type_agent
UPDATE public.agents_management
SET type_agent = 'principal'
WHERE type_agent IS NULL;

-- Recréer la contrainte CHECK (idempotente)
ALTER TABLE public.agents_management
DROP CONSTRAINT IF EXISTS agents_management_type_agent_check;

ALTER TABLE public.agents_management
ADD CONSTRAINT agents_management_type_agent_check
CHECK (type_agent IN ('principal', 'sous_agent', 'agent_regional', 'agent_local'));
