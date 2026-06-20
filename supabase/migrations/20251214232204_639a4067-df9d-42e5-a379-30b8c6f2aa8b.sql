-- Ajouter les colonnes pour la vente par carton (extension sans cassure)
ALTER TABLE public.products 
ADD COLUMN IF NOT EXISTS sell_by_carton boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS units_per_carton integer DEFAULT 1,
ADD COLUMN IF NOT EXISTS price_carton numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS carton_sku text;

-- Ajouter un commentaire pour documentation
COMMENT ON COLUMN public.products.sell_by_carton IS 'Indique si le produit peut être vendu par carton';
COMMENT ON COLUMN public.products.units_per_carton IS 'Nombre d unités par carton';
COMMENT ON COLUMN public.products.price_carton IS 'Prix de vente par carton';
COMMENT ON COLUMN public.products.carton_sku IS 'Code SKU du carton (optionnel)';