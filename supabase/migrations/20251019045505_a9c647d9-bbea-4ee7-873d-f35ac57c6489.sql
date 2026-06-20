-- Ajouter les colonnes manquantes pour les produits
ALTER TABLE public.products
ADD COLUMN IF NOT EXISTS is_hot BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS is_featured BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS free_shipping BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS reviews_count INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS rating NUMERIC(3,2) DEFAULT 0.0;

-- Créer des index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_products_hot ON public.products(is_hot) WHERE is_hot = true;
CREATE INDEX IF NOT EXISTS idx_products_featured ON public.products(is_featured) WHERE is_featured = true;
CREATE INDEX IF NOT EXISTS idx_products_rating ON public.products(rating DESC);