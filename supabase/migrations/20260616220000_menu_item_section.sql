-- ============================================================================
-- SECTION libre sur les plats (comme le `section` des produits vendeur), en plus de la catégorie.
-- Permet de regrouper/filtrer les plats au POS (ex. « Midi », « Soir », « Terrasse », « Bar »).
-- ============================================================================

ALTER TABLE public.restaurant_menu_items
  ADD COLUMN IF NOT EXISTS section text;

SELECT 'Colonne section ajoutée à restaurant_menu_items.' AS status;
