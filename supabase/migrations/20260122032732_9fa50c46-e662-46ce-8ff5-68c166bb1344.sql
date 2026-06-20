-- Ajouter la colonne section aux produits pour permettre aux vendeurs d'organiser leurs produits par section
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS section TEXT DEFAULT NULL;

-- Créer un index pour améliorer les performances des requêtes par section
CREATE INDEX IF NOT EXISTS idx_products_section ON public.products(section);

-- Créer un index composite pour les requêtes vendor + section
CREATE INDEX IF NOT EXISTS idx_products_vendor_section ON public.products(vendor_id, section);

COMMENT ON COLUMN public.products.section IS 'Section personnalisée du vendeur pour organiser les produits (ex: Moteurs, Accessoires, Carrosserie)';