-- ============================================================
-- 📊 KPI STOCKS CANONIQUES — fin du « profit > valeur » impossible
--
-- CAUSES PROUVÉES (audit 18/07) :
--  1. « Valeur Stock » était calculée CÔTÉ CLIENT (Σ prix_vente×qté, produits
--     ACTIFS seulement) tandis que « Profit » venait de get_inventory_stats
--     (SANS filtre is_active) → deux jeux de données différents.
--  2. get_inventory_stats lisait inventory.cost_price — colonne JAMAIS
--     alimentée (20/20 lignes vides en prod) : les coûts à 0 donnaient
--     profit = prix×qté PLEIN. Le PMP canonique vit dans products.cost_price
--     (alimenté par validate_stock_purchase et les réceptions B2B).
--  3. inventory.reserved_quantity est morte (0 partout) — les réservations
--     B2B vivent dans products.reserved_quantity (compartiment miroir).
--
-- DÉFINITIONS CANONIQUES (une seule requête, un seul jeu de données — les
-- produits ACTIFS du vendeur, quantité = inventory.quantity sinon
-- products.stock_quantity) :
--  - coût unitaire = NULLIF(products.cost_price, 0) — 0/NULL = INCONNU,
--    jamais « gratuit » ;
--  - valeur au coût  = Σ qté×coût (lignes au coût CONNU) ;
--  - valeur revente  = Σ qté×prix ;
--  - profit potentiel = Σ qté×(prix−coût) sur coût CONNU → TOUJOURS ≤ revente ;
--  - missing_cost_count = produits en stock SANS coût (à afficher, pas à taire).
-- Tout en GNF (devise de base) — la conversion d'affichage se fait UNE fois
-- côté client avec UN taux.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_inventory_stats(p_vendor_id uuid)
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_result json;
BEGIN
  SELECT json_build_object(
    'total_products', COUNT(*),
    'total_quantity', COALESCE(SUM(q.qty), 0),
    -- compat historique : total_value = valeur de REVENTE
    'total_value', COALESCE(SUM(q.qty * q.price), 0),
    'resale_value', COALESCE(SUM(q.qty * q.price), 0),
    'stock_cost_value', COALESCE(SUM(q.qty * q.cost) FILTER (WHERE q.cost IS NOT NULL), 0),
    'total_cost', COALESCE(SUM(q.qty * q.cost) FILTER (WHERE q.cost IS NOT NULL), 0),
    'potential_profit', COALESCE(SUM(q.qty * (q.price - q.cost)) FILTER (WHERE q.cost IS NOT NULL), 0),
    'missing_cost_count', COUNT(*) FILTER (WHERE q.cost IS NULL AND q.qty > 0),
    'low_stock_count', COUNT(*) FILTER (WHERE q.qty > 0 AND q.qty <= q.min_stock),
    'out_of_stock_count', COUNT(*) FILTER (WHERE q.qty = 0),
    'reserved_quantity', COALESCE(SUM(q.reserved), 0)
  ) INTO v_result
  FROM (
    SELECT
      COALESCE(i.quantity, p.stock_quantity, 0) AS qty,
      COALESCE(p.price, 0) AS price,
      NULLIF(COALESCE(p.cost_price, 0), 0) AS cost,
      COALESCE(i.minimum_stock, 10) AS min_stock,
      COALESCE(p.reserved_quantity, 0) AS reserved
    FROM public.products p
    LEFT JOIN LATERAL (
      SELECT quantity, minimum_stock
        FROM public.inventory
       WHERE product_id = p.id
       ORDER BY last_updated DESC NULLS LAST
       LIMIT 1
    ) i ON true
    WHERE p.vendor_id = p_vendor_id
      AND p.is_active = true
  ) q;

  RETURN v_result;
END $$;

REVOKE ALL ON FUNCTION public.get_inventory_stats(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_stats(uuid) TO authenticated, service_role;
