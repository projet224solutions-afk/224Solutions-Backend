-- ============================================================================
-- BLINDAGE flux ACHAT / paiement commande + Surveillance Plateforme
-- ----------------------------------------------------------------------------
-- create_order_core est déjà ATOMIQUE (1 transaction : validation stock + commande
-- + décrément stock + escrow + débit wallet, avec FOR UPDATE sur wallet et produits).
-- La route HTTP a déjà idempotencyGuard. Ce fichier ajoute :
--   1) IDEMPOTENCE PAIEMENT : index UNIQUE partiel sur orders.payment_intent_id →
--      un webhook paiement rejoué (card/mobile) ne peut PLUS créer 2 commandes pour
--      1 paiement (la 2e INSERT échoue → toute la transaction create_order_core est
--      annulée → AUCUN double-débit). Vérifié : aucun doublon existant.
--   2) order_monitor_report() : détection temps réel des anomalies commande, branché
--      sur la Surveillance Plateforme (nouveau domaine « Commandes »).
-- Non destructif, rejouable.
-- ============================================================================

-- 1) Anti double-paiement : un payment_intent_id ne peut référencer qu'UNE commande.
CREATE UNIQUE INDEX IF NOT EXISTS uniq_orders_payment_intent
  ON public.orders (payment_intent_id)
  WHERE payment_intent_id IS NOT NULL AND payment_intent_id <> '';

-- 2) Monitor du flux commande/paiement.
CREATE OR REPLACE FUNCTION public.order_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_no_escrow  int;
  v_dup_pi     int;
  v_neg_stock  int;
  v_rapid      int;
  v_nonpos     int;
BEGIN
  -- Commande PAYÉE mais sans escrow (hors cash COD) — argent encaissé, séquestre manquant.
  SELECT count(*) INTO v_no_escrow FROM public.orders o
  WHERE o.payment_status = 'paid'
    AND o.payment_method <> 'cash'
    AND o.created_at > now() - interval '7 days'
    AND NOT EXISTS (SELECT 1 FROM public.escrow_transactions e WHERE e.order_id = o.id);

  -- Doublon payment_intent_id (un paiement → 2 commandes). Doit rester 0 grâce à l'index.
  SELECT COALESCE(count(*), 0) INTO v_dup_pi FROM (
    SELECT 1 FROM public.orders
    WHERE payment_intent_id IS NOT NULL AND payment_intent_id <> ''
    GROUP BY payment_intent_id HAVING count(*) > 1
  ) d;

  -- Stock négatif (décrément incohérent).
  SELECT count(*) INTO v_neg_stock FROM public.products
  WHERE COALESCE(stock_quantity, 0) < 0;

  -- Rafale de commandes en 5 min (attaque/abus / bot).
  SELECT count(*) INTO v_rapid FROM public.orders
  WHERE created_at > now() - interval '5 minutes';

  -- Commande au montant total ≤ 0 (invalide).
  SELECT count(*) INTO v_nonpos FROM public.orders
  WHERE COALESCE(total_amount, 0) <= 0
    AND created_at > now() - interval '7 days';

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','order_paid_no_escrow','label','Commande payée sans escrow (séquestre manquant)','severity','high','count',v_no_escrow,'observed',v_no_escrow),
    jsonb_build_object('key','order_duplicate_payment_intent','label','Doublon payment_intent (1 paiement → 2 commandes)','severity','critical','count',v_dup_pi,'observed',v_dup_pi),
    jsonb_build_object('key','order_negative_stock','label','Stock produit négatif','severity','high','count',v_neg_stock,'observed',v_neg_stock),
    jsonb_build_object('key','order_rapid','label','Rafale de commandes (5 min) — possible bot/attaque','severity',CASE WHEN v_rapid > 50 THEN 'high' ELSE 'low' END,'count',CASE WHEN v_rapid > 50 THEN v_rapid ELSE 0 END,'observed',v_rapid),
    jsonb_build_object('key','order_nonpositive','label','Commande au montant total ≤ 0','severity','medium','count',v_nonpos,'observed',v_nonpos)
  ));
END;
$$;

REVOKE ALL ON FUNCTION public.order_monitor_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.order_monitor_report() TO service_role;

SELECT 'uniq_orders_payment_intent + order_monitor_report() créés.' AS status;
