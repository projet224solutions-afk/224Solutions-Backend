-- ============================================================================
-- Fix wallet_monitor_report : wallet_suspicious_activities utilise detected_at
-- (+ resolved_at), pas created_at. On corrige la colonne et on ne compte que
-- les activités critiques NON résolues. Non destructif, rejouable.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.wallet_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_neg      int;
  v_dup_dep  int;
  v_rapid_wd int;
  v_susp     int;
  v_large    int;
BEGIN
  SELECT count(*) INTO v_neg FROM public.wallets WHERE COALESCE(balance, 0) < 0;

  SELECT COALESCE(count(*), 0) INTO v_dup_dep FROM (
    SELECT 1 FROM public.wallet_transactions
    WHERE transaction_type::text IN ('deposit', 'mobile_money_in', 'admin_credit')
      AND NULLIF(metadata->>'reference', '') IS NOT NULL
      AND created_at > now() - interval '7 days'
    GROUP BY metadata->>'reference' HAVING count(*) > 1
  ) d;

  SELECT count(*) INTO v_rapid_wd FROM public.wallet_transactions
  WHERE transaction_type::text IN ('withdrawal', 'mobile_money_out')
    AND created_at > now() - interval '5 minutes';

  -- wallet_suspicious_activities : colonne detected_at (pas created_at) ; non résolues.
  SELECT count(*) INTO v_susp FROM public.wallet_suspicious_activities
  WHERE severity = 'critical'
    AND resolved_at IS NULL
    AND detected_at > now() - interval '24 hours';

  SELECT count(*) INTO v_large FROM public.wallet_transactions
  WHERE transaction_type::text IN ('withdrawal', 'mobile_money_out')
    AND COALESCE(amount, 0) > 2000000
    AND created_at > now() - interval '24 hours';

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','wallet_negative_balance','label','Wallet au solde négatif (sur-débit)','severity','critical','count',v_neg,'observed',v_neg),
    jsonb_build_object('key','wallet_duplicate_deposit','label','Dépôt dupliqué (même référence) — double-crédit','severity','high','count',v_dup_dep,'observed',v_dup_dep),
    jsonb_build_object('key','wallet_rapid_withdraw','label','Rafale de retraits (5 min) — possible drainage/attaque','severity',CASE WHEN v_rapid_wd > 20 THEN 'high' ELSE 'low' END,'count',CASE WHEN v_rapid_wd > 20 THEN v_rapid_wd ELSE 0 END,'observed',v_rapid_wd),
    jsonb_build_object('key','wallet_suspicious_critical','label','Activité suspecte critique non résolue (24h)','severity','high','count',v_susp,'observed',v_susp),
    jsonb_build_object('key','wallet_large_withdraw','label','Retrait de montant très élevé (24h) — à vérifier','severity','medium','count',v_large,'observed',v_large)
  ));
END;
$$;

REVOKE ALL ON FUNCTION public.wallet_monitor_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.wallet_monitor_report() TO service_role;

SELECT 'wallet_monitor_report() corrigé (detected_at + non résolues).' AS status;
