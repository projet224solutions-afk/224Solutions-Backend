-- Créer la table vendor_ratings pour stocker les notes des clients
CREATE TABLE IF NOT EXISTS public.vendor_ratings (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  customer_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(order_id, customer_id)
);

-- Index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_vendor_ratings_vendor_id ON public.vendor_ratings(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_ratings_customer_id ON public.vendor_ratings(customer_id);
CREATE INDEX IF NOT EXISTS idx_vendor_ratings_order_id ON public.vendor_ratings(order_id);

-- Enable RLS
ALTER TABLE public.vendor_ratings ENABLE ROW LEVEL SECURITY;

-- Policy: Tout le monde peut voir les notes (pour afficher la réputation des vendeurs)
CREATE POLICY "Les notes sont visibles par tous"
ON public.vendor_ratings
FOR SELECT
USING (true);

-- Policy: Les clients peuvent créer une note pour leur propre commande
CREATE POLICY "Les clients peuvent noter leurs commandes"
ON public.vendor_ratings
FOR INSERT
WITH CHECK (auth.uid() = customer_id);

-- Policy: Les clients peuvent modifier leur propre note
CREATE POLICY "Les clients peuvent modifier leurs notes"
ON public.vendor_ratings
FOR UPDATE
USING (auth.uid() = customer_id);

-- Fonction pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION public.update_vendor_ratings_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger pour updated_at
CREATE TRIGGER update_vendor_ratings_updated_at
BEFORE UPDATE ON public.vendor_ratings
FOR EACH ROW
EXECUTE FUNCTION public.update_vendor_ratings_updated_at();

-- Fonction pour calculer la note moyenne d'un vendeur
CREATE OR REPLACE FUNCTION public.get_vendor_average_rating(p_vendor_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSON;
BEGIN
  SELECT json_build_object(
    'average_rating', COALESCE(AVG(rating), 0),
    'total_ratings', COUNT(*),
    'rating_distribution', json_build_object(
      '5_stars', COUNT(*) FILTER (WHERE rating = 5),
      '4_stars', COUNT(*) FILTER (WHERE rating = 4),
      '3_stars', COUNT(*) FILTER (WHERE rating = 3),
      '2_stars', COUNT(*) FILTER (WHERE rating = 2),
      '1_star', COUNT(*) FILTER (WHERE rating = 1)
    )
  ) INTO v_result
  FROM vendor_ratings
  WHERE vendor_id = p_vendor_id;
  
  RETURN v_result;
END;
$$;