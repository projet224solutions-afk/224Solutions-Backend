-- ============================================================
-- 🧹 NETTOYAGE DU 3e SYSTÈME D'ENTREPÔTS (locations/location_stock)
-- Décision PDG 19/07 : une seule vérité = warehouses/warehouse_stocks
-- (relié au stock réel par trigger, certifié). Le sous-système
-- location_stock était orphelin TOTAL : 0 ligne partout, RPC jamais
-- appelées par aucun code (front et back vérifiés), UI supprimée.
--
-- PÉRIMÈTRE PRUDENT : les registres `locations` et `vendor_locations`
-- (1 ligne chacun) sont CONSERVÉS — des FK actives les référencent
-- (orders.location_id, stock_purchases.location_id, stock_losses) et le
-- POS multi-points de vente pourrait les réutiliser. Seul le SOUS-SYSTÈME
-- DE STOCK meurt.
-- ============================================================

-- 1) Vue
DROP VIEW IF EXISTS public.v_stock_by_location;

-- 2) RPC orphelines (toutes surcharges, par nom)
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN (
         'pos_sale_from_location', 'purchase_to_location', 'adjust_location_stock_atomic',
         'get_location_stats', 'get_product_stock_by_locations',
         'sync_location_stock_to_products', 'sync_location_stock_units',
         'create_stock_transfer', 'confirm_transfer_reception'
       )
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %s CASCADE', r.sig);
  END LOOP;
END $$;

-- 3) Tables du sous-système (toutes VIDES — vérifié avant : 0 ligne partout)
DROP TABLE IF EXISTS public.location_stock_movements CASCADE;
DROP TABLE IF EXISTS public.location_stock_history CASCADE;
DROP TABLE IF EXISTS public.location_stock CASCADE;
DROP TABLE IF EXISTS public.location_permissions CASCADE;
DROP TABLE IF EXISTS public.location_access CASCADE;
DROP TABLE IF EXISTS public.stock_transfer_items CASCADE;
DROP TABLE IF EXISTS public.stock_transfers CASCADE;
