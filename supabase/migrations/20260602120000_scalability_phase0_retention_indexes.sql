-- ============================================================================
-- SCALABILITÉ — PHASE 0 : rétention télémétrie/audit + index chauds
-- ----------------------------------------------------------------------------
-- Objectif : limiter la croissance de la base (la télémétrie explose :
-- ~80k lignes core_feature_health_events pour ~28 comptes) et accélérer les
-- requêtes chaudes (livraisons, courses, suivi).
-- Sûr & idempotent : peut être ré-exécuté sans risque.
-- ============================================================================

-- 1) Index chauds (tables petites/vides aujourd'hui → création instantanée)
CREATE INDEX IF NOT EXISTS idx_cfhe_created_at       ON public.core_feature_health_events (created_at);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON public.audit_logs (created_at);
CREATE INDEX IF NOT EXISTS idx_deliveries_driver_id  ON public.deliveries (driver_id);
CREATE INDEX IF NOT EXISTS idx_deliveries_status     ON public.deliveries (status);
CREATE INDEX IF NOT EXISTS idx_taxi_trips_driver_id  ON public.taxi_trips (driver_id);
CREATE INDEX IF NOT EXISTS idx_delivery_tracking_did ON public.delivery_tracking (delivery_id);

-- 2) Fonctions de purge (rétention)
--    Télémétrie : 30 jours. Audit : 90 jours (conformité).
CREATE OR REPLACE FUNCTION public.purge_old_telemetry()
RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  DELETE FROM public.core_feature_health_events
  WHERE created_at < now() - interval '30 days';
$$;

CREATE OR REPLACE FUNCTION public.purge_old_audit_logs()
RETURNS void LANGUAGE sql SECURITY DEFINER AS $$
  DELETE FROM public.audit_logs
  WHERE created_at < now() - interval '90 days';
$$;

-- 3) Planification quotidienne via pg_cron (idempotent, tolérant si pg_cron absent)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- Retirer d'éventuels jobs existants pour éviter les doublons
    PERFORM cron.unschedule(jobid)
    FROM cron.job
    WHERE jobname IN ('purge-telemetry', 'purge-audit-logs');

    PERFORM cron.schedule('purge-telemetry',  '0 3 * * *',  'SELECT public.purge_old_telemetry();');
    PERFORM cron.schedule('purge-audit-logs', '15 3 * * *', 'SELECT public.purge_old_audit_logs();');
  END IF;
END$$;

-- 4) Purge immédiate d'amorçage (récupère l'espace dès l'application)
SELECT public.purge_old_telemetry();
SELECT public.purge_old_audit_logs();
