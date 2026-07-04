-- ============================================================================
-- 👁️ SURVEILLANCE POS — détecter les ventes de l'ANCIEN fallback qui corrompait le stock
-- ----------------------------------------------------------------------------
-- CONTEXTE : le repli `createCashOrderFallbackDirect` (retiré du frontend) insérait
-- directement orders + order_items SANS décrémenter le stock ni créer de pos_sales →
-- inventaire corrompu (order_items sans mouvement de stock). Ces ventes portent le
-- MARQUEUR EXACT écrit par ce code : source='pos' + notes = « Fallback POS cash
-- (backend indisponible) ». La table stock_movements est vide/inutilisée pour le POS
-- (le décrément passe par products.stock_quantity via RPC atomique), donc la détection
-- fiable se fait sur ce marqueur, pas sur une jointure stock_movements (qui flaggerait tout).
--
-- Nouveau contrôle `pos_items_without_stock_movement` : compte ces ventes historiques.
-- On NE régularise PAS automatiquement (correction de stock = décision métier) — on ALERTE
-- le vendeur/PDG. Auto-résolu quand count=0 (même pattern que les autres monitors).
--
-- Reprend À L'IDENTIQUE les 5 contrôles existants (20260608270000) + ajoute le 6e.
-- Non destructif, rejouable.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pos_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stock_pending  int;
  v_neg_stock      int;
  v_incoherent     int;
  v_credit_overdue int;
  v_rapid          int;
  v_fallback       int;
BEGIN
  SELECT count(*) INTO v_stock_pending FROM public.pos_stock_reconciliation WHERE status = 'pending';

  SELECT count(*) INTO v_neg_stock FROM public.products WHERE COALESCE(stock_quantity, 0) < 0;

  SELECT count(*) INTO v_incoherent FROM public.pos_sales
  WHERE created_at > now() - interval '30 days'
    AND ABS(COALESCE(total_amount,0)
            - GREATEST(0, COALESCE(subtotal,0) + COALESCE(tax_amount,0) - COALESCE(discount_total,0))) > 1;

  SELECT count(*) INTO v_credit_overdue FROM public.vendor_credit_sales
  WHERE status = 'pending' AND due_date < now() AND COALESCE(remaining_amount, 0) > 0;

  SELECT count(*) INTO v_rapid FROM public.pos_sales WHERE created_at > now() - interval '5 minutes';

  -- 🆕 Ventes créées par l'ancien fallback direct (order_items SANS mouvement de stock).
  -- Marqueur exact du code retiré : source='pos' + notes « Fallback POS cash… ».
  SELECT count(*) INTO v_fallback FROM public.orders o
  WHERE o.source = 'pos'
    AND o.notes ILIKE '%Fallback POS cash%'
    AND EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id = o.id);

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','pos_stock_pending','label','Réconciliations stock POS en attente (vente sans décrément → sur-vente)','severity','high','count',v_stock_pending,'observed',v_stock_pending),
    jsonb_build_object('key','pos_negative_stock','label','Produit au stock négatif (sur-vente)','severity','high','count',v_neg_stock,'observed',v_neg_stock),
    jsonb_build_object('key','pos_sale_incoherent','label','Vente POS au total incohérent (≠ sous-total + taxe − remise)','severity','medium','count',v_incoherent,'observed',v_incoherent),
    jsonb_build_object('key','pos_credit_overdue','label','Ventes à crédit échues impayées (recouvrement)','severity','low','count',v_credit_overdue,'observed',v_credit_overdue),
    jsonb_build_object('key','pos_rapid_sales','label','Rafale de ventes POS (5 min) — possible bot/abus','severity',CASE WHEN v_rapid > 50 THEN 'high' ELSE 'low' END,'count',CASE WHEN v_rapid > 50 THEN v_rapid ELSE 0 END,'observed',v_rapid),
    jsonb_build_object('key','pos_items_without_stock_movement','label','Ventes POS de l''ancien fallback (order_items SANS décrément de stock → inventaire à corriger)','severity','high','count',v_fallback,'observed',v_fallback)
  ));
END;
$$;

REVOKE ALL ON FUNCTION public.pos_monitor_report() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_monitor_report() TO service_role;

-- Vérification + décompte des ventes historiques concernées (à consulter après application).
SELECT
  CASE WHEN public.pos_monitor_report()::text LIKE '%pos_items_without_stock_movement%'
    THEN '✅ pos_monitor_report : contrôle « pos_items_without_stock_movement » actif'
    ELSE '❌ ÉCHEC : contrôle absent' END AS status,
  (SELECT count(*) FROM public.orders o
   WHERE o.source = 'pos' AND o.notes ILIKE '%Fallback POS cash%'
     AND EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id = o.id)) AS ventes_historiques_a_corriger;
