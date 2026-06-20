-- Ajouter la colonne video_url à la table digital_products
ALTER TABLE public.digital_products 
ADD COLUMN IF NOT EXISTS video_url TEXT;

-- Ajouter un commentaire pour documenter
COMMENT ON COLUMN public.digital_products.video_url IS 'URL de la vidéo de présentation du produit (max 5 secondes)';