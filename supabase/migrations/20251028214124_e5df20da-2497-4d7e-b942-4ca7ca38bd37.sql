-- Ajouter les colonnes manquantes à la table profiles
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS country TEXT,
ADD COLUMN IF NOT EXISTS city TEXT,
ADD COLUMN IF NOT EXISTS custom_id TEXT;

-- Créer un index sur custom_id pour les recherches rapides
CREATE INDEX IF NOT EXISTS idx_profiles_custom_id ON public.profiles(custom_id);

-- Ajouter un commentaire pour documenter les colonnes
COMMENT ON COLUMN public.profiles.country IS 'Pays de l''utilisateur';
COMMENT ON COLUMN public.profiles.city IS 'Ville/commune de l''utilisateur';
COMMENT ON COLUMN public.profiles.custom_id IS 'Identifiant personnalisé unique (3 lettres + 4 chiffres)';