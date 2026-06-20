-- Ajouter la colonne category aux fournisseurs
ALTER TABLE public.vendor_suppliers ADD COLUMN IF NOT EXISTS category TEXT DEFAULT NULL;

-- Créer un index pour les filtres par catégorie
CREATE INDEX IF NOT EXISTS idx_vendor_suppliers_category ON public.vendor_suppliers(category);