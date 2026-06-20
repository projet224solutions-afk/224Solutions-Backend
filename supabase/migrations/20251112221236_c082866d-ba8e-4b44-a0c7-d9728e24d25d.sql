
-- Supprimer les anciennes fonctions release_escrow qui créent l'ambiguïté
DROP FUNCTION IF EXISTS public.release_escrow(uuid, numeric);
DROP FUNCTION IF EXISTS public.release_escrow(uuid, numeric, uuid);

-- La fonction release_escrow_funds existe déjà et sera utilisée par les Edge Functions
