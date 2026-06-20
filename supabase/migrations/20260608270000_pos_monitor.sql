-- ============================================================================
-- Surveillance flux POS (caisse vendeur) — détection temps réel
-- ----------------------------------------------------------------------------
-- Le POS est déjà atomique + idempotent (create_pos_sale_complete /
-- create_pos_order_complete : idempotence UNIQUE en base, taxe server-side,
-- stock verrouillé FOR UPDATE, file pos_stock_reconciliation). Ce capteur
-- détecte les dérives résiduelles :
--   • réconciliations stock en attente (vente enregistrée SANS décrément → sur-vente),
--   • produit au stock négatif (sur-vente concurrente),
--   • total POS incohérent (≠ sous-total + taxe − remise) sur 30j,
--   • ventes à crédit échues impayées (suivi financier),
--   • rafale de ventes POS (5 min) — possible bot/abus.
-- Branché dans MONITOR_DOMAINS (onglet « POS »). Non destructif, rejouable.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pos_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stock_pending int;
  v_neg_stock     int;
  v_incoherent    int;
  v_credit_overdue int;
  v_rapid         int;
BEGIN
  -- Réconciliations stock en attente = vente POS sans décrément effectif (risque sur-vente).
  SELECT count(*) INTO v_stock_pending FROM public.pos_stock_reconciliation WHERE status = 'pending';

  -- Produit au stock négatif (ne doit jamais arriver : GREATEST(0,...) partout).
  SELECT count(*) INTO v_neg_stock FROM public.products WHERE COALESCE(stock_quantity, 0) < 0;

  -- Total POS incohérent : total_amount ≠ GREATEST(0, subtotal + tax − remise). 30 derniers jours
  -- (les ventes legacy backfillées sans taxe ne polluent pas indéfiniment).
  SELECT count(*) INTO v_incoherent FROM public.pos_sales
  WHERE created_at > now() - interval '30 days'
    AND ABS(COALESCE(total_amount,0)
            - GREATEST(0, COALESCE(subtotal,0) + COALESCE(tax_amount,0) - COALESCE(discount_total,0))) > 1;

  -- Ventes à crédit échues impayées (suivi : recouvrement vendeur).
  SELECT count(*) INTO v_credit_overdue FROM public.vendor_credit_sales
  WHERE status = 'pending' AND due_date < now() AND COALESCE(remaining_amount, 0) > 0;

  -- Rafale de ventes POS en 5 min — possible bot / abus de synchronisation.
  SELECT count(*) INTO v_rapid FROM public.pos_sales WHERE created_at > now() - interval '5 minutes';

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','pos_stock_pending','label','Réconciliations stock POS en attente (vente sans décrément → sur-vente)','severity','high','count',v_stock_pending,'observed',v_stock_pending),
    jsonb_build_object('key','pos_negative_stock','label','Produit au stock négatif (sur-vente)','severity','high','count',v_neg_stock,'observed',v_neg_stock),
    jsonb_build_object('key','pos_sale_incoherent','label','Vente POS au total incohérent (≠ sous-total + taxe − remise)','severity','medium','count',v_incoherent,'observed',v_incoherent),
    jsonb_build_object('key','pos_credit_overdue','label','Ventes à crédit échues impayées (recouvrement)','severity','low','count',v_credit_overdue,'observed',v_credit_overdue),
    jsonb_build_object('key','pos_rapid_sales','label','Rafale de ventes POS (5 min) — possible bot/abus','severity',CASE WHEN v_rapid > 50 THEN 'high' ELSE 'low' END,'count',CASE WHEN v_rapid > 50 THEN v_rapid ELSE 0 END,'observed',v_rapid)
  ));
END;
$$;

REVOKE ALL ON FUNCTION public.pos_monitor_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pos_monitor_report() TO service_role;

SELECT 'pos_monitor_report() créé (5 capteurs POS).' AS status;
