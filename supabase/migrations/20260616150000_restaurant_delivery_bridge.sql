-- ============================================================================
-- INTÉGRATION LIVRAISON RESTAURANT ↔ SYSTÈME LIVREUR EXISTANT (Étape 1 : pont données).
-- La table `deliveries` (dispatch livreur + GPS via tracking_points/Ably + carte) était liée
-- UNIQUEMENT à `orders` (e-commerce) via order_id NOT NULL. On la rend polyvalente :
--   - order_id devient NULLABLE,
--   - restaurant_order_id (FK restaurant_orders) ajouté,
--   - au moins une des deux références exigée,
--   - une seule livraison par commande restaurant (idempotence).
-- Aucune donnée existante impactée (les livraisons e-commerce gardent order_id).
-- ============================================================================

ALTER TABLE public.deliveries ALTER COLUMN order_id DROP NOT NULL;

ALTER TABLE public.deliveries
  ADD COLUMN IF NOT EXISTS restaurant_order_id uuid REFERENCES public.restaurant_orders(id) ON DELETE CASCADE;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_deliveries_restaurant_order
  ON public.deliveries(restaurant_order_id) WHERE restaurant_order_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_deliveries_status ON public.deliveries(status);

-- Au moins une référence de commande (NOT VALID = ne revalide pas les lignes existantes).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'deliveries_one_order_ref') THEN
    ALTER TABLE public.deliveries
      ADD CONSTRAINT deliveries_one_order_ref
      CHECK (order_id IS NOT NULL OR restaurant_order_id IS NOT NULL) NOT VALID;
  END IF;
END $$;

SELECT 'Pont livraison restaurant : deliveries.order_id nullable + restaurant_order_id (FK, unique) ajouté.' AS status;
