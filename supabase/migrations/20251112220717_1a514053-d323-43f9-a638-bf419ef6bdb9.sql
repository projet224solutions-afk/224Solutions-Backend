
-- Corriger la clé étrangère owner_member_id pour pointer vers syndicate_workers au lieu de members

-- 1. Supprimer l'ancienne contrainte FK qui pointe vers members
ALTER TABLE public.vehicles 
DROP CONSTRAINT IF EXISTS vehicles_owner_member_id_fkey;

-- 2. Créer la nouvelle contrainte FK vers syndicate_workers
ALTER TABLE public.vehicles
ADD CONSTRAINT vehicles_owner_member_id_fkey 
FOREIGN KEY (owner_member_id) 
REFERENCES public.syndicate_workers(id) 
ON DELETE SET NULL;

-- 3. Créer un index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_vehicles_owner_member_id 
ON public.vehicles(owner_member_id);

-- Commentaire pour documenter la correction
COMMENT ON CONSTRAINT vehicles_owner_member_id_fkey ON public.vehicles IS 
'Clé étrangère vers syndicate_workers - Corrigé pour pointer vers la bonne table';
