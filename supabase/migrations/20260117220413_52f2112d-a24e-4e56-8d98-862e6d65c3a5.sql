-- Supprimer l'ancienne contrainte check
ALTER TABLE public.digital_products DROP CONSTRAINT IF EXISTS digital_products_category_check;

-- Recréer la contrainte avec la nouvelle catégorie physique_affilie
ALTER TABLE public.digital_products ADD CONSTRAINT digital_products_category_check 
CHECK (category IN ('dropshipping', 'voyage', 'logiciel', 'formation', 'livre', 'custom', 'ai', 'physique_affilie'));