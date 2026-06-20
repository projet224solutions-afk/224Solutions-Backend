-- Ajouter les colonnes pour les réponses du vendeur aux avis
ALTER TABLE public.vendor_ratings
ADD COLUMN IF NOT EXISTS vendor_response TEXT,
ADD COLUMN IF NOT EXISTS vendor_response_at TIMESTAMPTZ;