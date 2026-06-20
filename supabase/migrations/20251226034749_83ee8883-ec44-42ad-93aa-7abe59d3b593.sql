-- Ajouter la colonne cover_image_url à la table vendors si elle n'existe pas
ALTER TABLE public.vendors 
ADD COLUMN IF NOT EXISTS cover_image_url TEXT;