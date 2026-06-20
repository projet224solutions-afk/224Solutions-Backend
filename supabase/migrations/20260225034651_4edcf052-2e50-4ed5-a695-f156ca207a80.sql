-- Fix: le trigger wishlist doit s'exécuter uniquement pour les favoris PRODUITS
-- car log_product_interaction attend un product_id non-null.

BEGIN;

DROP TRIGGER IF EXISTS track_wishlist_addition ON public.wishlists;

CREATE TRIGGER track_wishlist_addition
AFTER INSERT ON public.wishlists
FOR EACH ROW
WHEN (NEW.product_id IS NOT NULL)
EXECUTE FUNCTION public.log_product_interaction('wishlist', '3');

COMMIT;