-- Création de la table product_views pour le tracking des vues produits
CREATE TABLE IF NOT EXISTS public.product_views (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  product_id UUID NOT NULL,
  session_id TEXT,
  metadata JSONB DEFAULT '{}',
  viewed_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Index pour les requêtes fréquentes
CREATE INDEX IF NOT EXISTS idx_product_views_user_id ON public.product_views(user_id);
CREATE INDEX IF NOT EXISTS idx_product_views_product_id ON public.product_views(product_id);
CREATE INDEX IF NOT EXISTS idx_product_views_viewed_at ON public.product_views(viewed_at DESC);

-- Enable RLS
ALTER TABLE public.product_views ENABLE ROW LEVEL SECURITY;

-- Policy: Users can insert their own views
CREATE POLICY "Users can insert their own views"
ON public.product_views
FOR INSERT
WITH CHECK (auth.uid() = user_id);

-- Policy: Users can view their own history
CREATE POLICY "Users can view their own views"
ON public.product_views
FOR SELECT
USING (auth.uid() = user_id);

-- Comment
COMMENT ON TABLE public.product_views IS 'Tracking des vues de produits pour les recommandations';