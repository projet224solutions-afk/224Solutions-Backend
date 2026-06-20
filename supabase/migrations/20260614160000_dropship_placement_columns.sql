-- ============================================================================
-- DROPSHIPPING — Phase 3 : colonnes de PLACEMENT fournisseur (exécution serveur)
-- ----------------------------------------------------------------------------
-- Le placement de la commande chez le fournisseur passe désormais par le BACKEND
-- (clés API fournisseur côté serveur, jamais au navigateur). On stocke le résultat
-- du placement sur la commande fournisseur. Non destructif, rejouable.
-- ============================================================================

ALTER TABLE public.dropship_orders
  ADD COLUMN IF NOT EXISTS supplier_order_id        text,
  ADD COLUMN IF NOT EXISTS supplier_order_reference text,
  ADD COLUMN IF NOT EXISTS placed_at                timestamptz,
  ADD COLUMN IF NOT EXISTS placement_error          text,
  ADD COLUMN IF NOT EXISTS placement_is_mock        boolean;

-- Recherche rapide d'une commande fournisseur par son id externe (rapprochement tracking).
CREATE INDEX IF NOT EXISTS idx_dropship_orders_supplier_order_id
  ON public.dropship_orders (supplier_order_id);

SELECT 'Colonnes de placement dropship ajoutées (supplier_order_id, reference, placed_at, placement_error, placement_is_mock).' AS status;
