-- Ajouter la colonne has_password pour suivre si un utilisateur OAuth a défini un mot de passe
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS has_password boolean DEFAULT false;

-- Mettre à jour les profils existants: les utilisateurs qui se sont inscrits par email ont déjà un mot de passe
-- On ne peut pas savoir avec certitude, donc on laisse à false par défaut
-- Les utilisateurs devront définir leur mot de passe s'ils ne l'ont pas encore fait

-- Index pour la performance des requêtes
CREATE INDEX IF NOT EXISTS idx_profiles_has_password ON public.profiles(has_password);