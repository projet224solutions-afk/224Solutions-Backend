-- Ajouter la colonne status à la table profiles pour la présence en ligne
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'offline' CHECK (status IN ('online', 'busy', 'offline'));