-- ============================================================================
-- 🛡️ DOMAINE SURVEILLANCE « money_integrity » — branche le watchdog argent dans la
-- surveillance PDG (system_alerts). Format standard <x>_monitor_report().
--
-- Détecte la CAUSE RACINE des fuites récentes : surcharges de fonctions argent en double
-- (vieille version qui capte les appels), credit_user_wallet_safe non-convertissant, et
-- escrows libérés sans commission. → alerte critique automatique dans « Surveillance Plateforme ».
-- ============================================================================

CREATE OR REPLACE FUNCTION public.money_integrity_report()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dup int;
  v_fx  int;
  v_noc int;
BEGIN
  -- 1) Fonctions argent ayant >1 surcharge (drift = vieille version qui capte les appels).
  SELECT count(*) INTO v_dup FROM (
    SELECT p.proname
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname ~* '(credit_user_wallet_safe|create_order_core|release_escrow_to_seller|execute_atomic_wallet_transfer|refund_order_escrow|purchase_.*_subscription|create_pos_sale_complete)'
    GROUP BY p.proname HAVING count(*) > 1
  ) d;

  -- 2) credit_user_wallet_safe sans le garde FX (= ancienne version non-convertissante).
  SELECT CASE WHEN EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'credit_user_wallet_safe'
      AND pg_get_functiondef(p.oid) LIKE '%FX_RATE_MISSING%'
  ) THEN 0 ELSE 1 END INTO v_fx;

  -- 3) Escrows libérés sans commission prélevée (fuite commission vendeur).
  SELECT count(*) INTO v_noc
  FROM public.escrow_transactions e JOIN public.orders o ON o.id = e.order_id
  WHERE e.status = 'released' AND COALESCE(e.commission_amount, 0) = 0;

  RETURN jsonb_build_object(
    'generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','money_duplicate_overload','label','Surcharges de fonctions argent en double (drift)','severity','critical','count',v_dup,'observed',v_dup),
      jsonb_build_object('key','credit_fx_not_converting','label','credit_user_wallet_safe sans conversion de devise','severity','critical','count',v_fx,'observed',v_fx),
      jsonb_build_object('key','escrow_released_no_commission','label','Escrows libérés sans commission prélevée','severity','critical','count',v_noc,'observed',v_noc)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.money_integrity_report() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.money_integrity_report() TO authenticated, service_role;

SELECT 'Domaine money_integrity prêt (money_integrity_report). À ajouter dans MONITOR_DOMAINS (escrowMonitor.service.ts).' AS status;
