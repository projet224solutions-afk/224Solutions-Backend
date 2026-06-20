-- 🩺 SURVEILLANCE ABONNEMENTS (tous types) — RPC de détection d'anomalies (lecture seule)
--
-- Couvre les 3 types : vendeur (subscriptions), chauffeur (driver_subscriptions),
-- service (service_subscriptions). Même format que escrow_monitor_report.
-- Anomalies : expiré-mais-actif (cron expire-check en panne), actif sans date de fin, création en rafale.

CREATE OR REPLACE FUNCTION public.subscription_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_exp_vendor  int;
  v_exp_driver  int;
  v_exp_service int;
  v_no_period   int;
  v_spike       int;
BEGIN
  -- Expiré mais encore 'active' (la date de fin est passée → le cron aurait dû l'expirer)
  SELECT count(*) INTO v_exp_vendor FROM public.subscriptions
  WHERE status = 'active' AND current_period_end IS NOT NULL AND current_period_end < now();

  SELECT count(*) INTO v_exp_driver FROM public.driver_subscriptions
  WHERE status = 'active' AND end_date IS NOT NULL AND end_date < now();

  SELECT count(*) INTO v_exp_service FROM public.service_subscriptions
  WHERE status = 'active' AND current_period_end IS NOT NULL AND current_period_end < now();

  -- Actif sans date de fin (intégrité — facturation impossible à borner)
  SELECT count(*) INTO v_no_period FROM (
    SELECT id FROM public.subscriptions         WHERE status = 'active' AND current_period_end IS NULL
    UNION ALL
    SELECT id FROM public.service_subscriptions WHERE status = 'active' AND current_period_end IS NULL
  ) x;

  -- Création d'abonnements en rafale (5 min) — possible abus / attaque
  SELECT (
      (SELECT count(*) FROM public.subscriptions         WHERE created_at > now() - interval '5 minutes')
    + (SELECT count(*) FROM public.driver_subscriptions  WHERE created_at > now() - interval '5 minutes')
    + (SELECT count(*) FROM public.service_subscriptions WHERE created_at > now() - interval '5 minutes')
  ) INTO v_spike;

  RETURN jsonb_build_object(
    'generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','sub_expired_active_vendor','label','Abonnement vendeur expiré mais actif','severity','high','count',v_exp_vendor,'observed',v_exp_vendor),
      jsonb_build_object('key','sub_expired_active_driver','label','Abonnement chauffeur expiré mais actif','severity','high','count',v_exp_driver,'observed',v_exp_driver),
      jsonb_build_object('key','sub_expired_active_service','label','Abonnement service expiré mais actif','severity','high','count',v_exp_service,'observed',v_exp_service),
      jsonb_build_object('key','sub_active_no_period','label','Abonnement actif sans date de fin','severity','medium','count',v_no_period,'observed',v_no_period),
      jsonb_build_object('key','sub_creation_spike','label','Création d''abonnements en rafale (5 min) — possible abus','severity',CASE WHEN v_spike > 20 THEN 'high' ELSE 'low' END,'count',CASE WHEN v_spike > 20 THEN v_spike ELSE 0 END,'observed',v_spike)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.subscription_monitor_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.subscription_monitor_report() TO service_role;

SELECT 'subscription_monitor_report() créée — 5 contrôles (vendeur/chauffeur/service).' AS status;
