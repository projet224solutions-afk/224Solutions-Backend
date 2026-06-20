-- Table pour les liens partagés avec tracking
CREATE TABLE public.shared_links (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  short_code VARCHAR(20) NOT NULL UNIQUE,
  original_url TEXT NOT NULL,
  title TEXT NOT NULL,
  link_type VARCHAR(50) NOT NULL DEFAULT 'other',
  resource_id UUID,
  views_count INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id),
  expires_at TIMESTAMP WITH TIME ZONE,
  is_active BOOLEAN NOT NULL DEFAULT true,
  metadata JSONB
);

-- Index pour recherche rapide par short_code
CREATE INDEX idx_shared_links_short_code ON public.shared_links(short_code);

-- Index pour les liens actifs
CREATE INDEX idx_shared_links_active ON public.shared_links(is_active) WHERE is_active = true;

-- Enable RLS
ALTER TABLE public.shared_links ENABLE ROW LEVEL SECURITY;

-- Politique: Tout le monde peut lire les liens actifs
CREATE POLICY "Anyone can read active shared links"
ON public.shared_links
FOR SELECT
USING (is_active = true);

-- Politique: Utilisateurs authentifiés peuvent créer des liens
CREATE POLICY "Authenticated users can create shared links"
ON public.shared_links
FOR INSERT
TO authenticated
WITH CHECK (true);

-- Politique: Créateurs peuvent mettre à jour leurs liens
CREATE POLICY "Users can update their own shared links"
ON public.shared_links
FOR UPDATE
USING (auth.uid() = created_by);

-- Fonction pour incrémenter le compteur de vues
CREATE OR REPLACE FUNCTION public.increment_shared_link_views(p_short_code VARCHAR)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE shared_links 
  SET views_count = views_count + 1 
  WHERE short_code = p_short_code AND is_active = true;
END;
$$;