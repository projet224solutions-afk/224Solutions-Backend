-- Ajouter la colonne country à la table vendors
ALTER TABLE public.vendors ADD COLUMN IF NOT EXISTS country TEXT DEFAULT 'Guinée';

-- Mettre à jour les enregistrements existants avec la valeur par défaut
UPDATE public.vendors SET country = 'Guinée' WHERE country IS NULL;