-- Ajouter une colonne badge_title à la table vehicles pour stocker le titre personnalisé du badge
ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS badge_title TEXT;

-- Mettre à jour le commentaire
COMMENT ON COLUMN public.vehicles.badge_title IS 'Titre personnalisé du badge taxi-moto';