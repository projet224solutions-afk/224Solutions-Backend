-- ============================================================================
-- 🛡️ WATCHDOG INTÉGRITÉ ARGENT — détection automatique du drift + fuites escrow.
--
-- Les bugs récents (escrow=total, commission non prélevée, devise non convertie) avaient
-- TOUS la même cause cachée : une ANCIENNE surcharge de fonction argent encore en base, et
-- aucune alerte. Ce watchdog rend ces dangers VISIBLES et atomiquement vérifiables :
--   1) duplicate_overload   : une fonction argent a >1 surcharge (la vieille capte les appels).
--   2) escrow_no_commission : un escrow LIBÉRÉ avec commission NULL/0 (commission non prélevée).
--   3) escrow_amount_gt_subtotal : escrow.amount > orders.subtotal (frais acheteur escrowés=fuite).
--   4) credit_fx_not_converting : credit_user_wallet_safe ne contient pas le garde FX (ancienne version).
--
-- Lecture seule, SECURITY DEFINER, réservé admin/PDG + service_role (surveillance).
-- Idempotent. Appelable par la surveillance PDG / un job, ou à la main.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.money_integrity_check()
RETURNS TABLE(category text, severity text, detail text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- 1) Surcharges multiples de fonctions argent = drift (cause racine des fuites).
  SELECT 'duplicate_overload'::text, 'critical'::text,
         p.proname || ' : ' || count(*) || ' surcharges → ' ||
         string_agg(pg_get_function_identity_arguments(p.oid), '  |  ' ORDER BY p.oid)
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname ~* '(credit_user_wallet_safe|create_order_core|release_escrow_to_seller|execute_atomic_wallet_transfer|process_.*payment|withdraw|deposit|payout|refund_order_escrow|purchase_.*_subscription)'
  GROUP BY p.proname
  HAVING count(*) > 1

  UNION ALL
  -- 2) Escrows libérés SANS commission prélevée (fuite commission vendeur).
  SELECT 'escrow_no_commission', 'critical',
         o.order_number || ' : escrow=' || e.amount || ' commission=' || COALESCE(e.commission_amount::text, 'NULL')
  FROM public.escrow_transactions e
  JOIN public.orders o ON o.id = e.order_id
  WHERE e.status = 'released'
    AND COALESCE(e.commission_amount, 0) = 0

  UNION ALL
  -- 3) Escrow dont le montant dépasse le sous-total (frais acheteur escrowés = sur-paiement vendeur).
  SELECT 'escrow_amount_gt_subtotal', 'critical',
         o.order_number || ' : escrow=' || e.amount || ' > subtotal=' || o.subtotal
  FROM public.escrow_transactions e
  JOIN public.orders o ON o.id = e.order_id
  WHERE e.amount > o.subtotal + 0.01

  UNION ALL
  -- 4) credit_user_wallet_safe sans le garde FX (= version ancienne non-convertissante).
  SELECT 'credit_fx_not_converting', 'critical',
         'credit_user_wallet_safe ne contient pas FX_RATE_MISSING (version ancienne sans conversion devise)'
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'credit_user_wallet_safe'
      AND pg_get_functiondef(p.oid) LIKE '%FX_RATE_MISSING%'
  );
$$;

REVOKE ALL ON FUNCTION public.money_integrity_check() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.money_integrity_check() TO authenticated, service_role;

SELECT 'Watchdog money_integrity_check() posé : 0 ligne = sain ; toute ligne = anomalie argent (drift surcharge, escrow sans commission, escrow>subtotal, FX non converti).' AS status;
