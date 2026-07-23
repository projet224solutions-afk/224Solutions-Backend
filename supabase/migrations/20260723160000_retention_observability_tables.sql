-- ============================================================================
-- RÉTENTION DES TABLES D'OBSERVABILITÉ — plafond structurel #1 aujourd'hui
-- ============================================================================
-- Constat audit (23/07/2026) : le catalogue est minuscule (48 produits, 112 Ko)
-- et déjà bien indexé. Ce qui étouffe l'instance Micro, ce sont les tables de
-- télémétrie SANS rétention :
--   core_feature_health_events  283k lignes  142 Mo  (~9 400 events/jour)
--   job_execution_log           359k lignes   94 Mo  (aucune rétention)
--   fx_collection_log           203k lignes   56 Mo  (aucune rétention)
--   monitoring_events            77k lignes   18 Mo  (aucune rétention)
--   system_metrics               28k lignes    6 Mo  (aucune rétention)
--
-- purge_old_telemetry() ne couvrait QUE core_feature_health_events (30j).
-- On l'ÉTEND (CLAUDE.md : étendre, ne pas dupliquer) à toutes les tables
-- d'observabilité, avec une fenêtre par table. Le job pg_cron `purge-telemetry`
-- (03:00 UTC, SELECT public.purge_old_telemetry();) reste inchangé et couvre
-- désormais tout.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.purge_old_telemetry()
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  -- Santé des features : 14j suffisent largement (volume ~9 400/jour).
  DELETE FROM public.core_feature_health_events WHERE created_at  < now() - interval '14 days';
  -- Journal d'exécution des jobs : 1 mois d'historique.
  DELETE FROM public.job_execution_log          WHERE created_at  < now() - interval '30 days';
  -- Collecte des taux de change (horaire par devise) : 2 mois.
  DELETE FROM public.fx_collection_log          WHERE collected_at < now() - interval '60 days';
  -- Événements de supervision : 1 mois.
  DELETE FROM public.monitoring_events          WHERE created_at  < now() - interval '30 days';
  -- Métriques système : 1 mois.
  DELETE FROM public.system_metrics             WHERE recorded_at < now() - interval '30 days';
  -- Vues produit brutes (agrégées ailleurs) : 90j.
  DELETE FROM public.product_views_raw          WHERE created_at  < now() - interval '90 days';
$function$;

COMMENT ON FUNCTION public.purge_old_telemetry() IS
  'Rétention des tables d''observabilité. Appelée quotidiennement par le job pg_cron purge-telemetry (03:00 UTC). Fenêtres : health 14j, jobs 30j, fx 60j, monitoring 30j, metrics 30j, views 90j.';

-- ---------------------------------------------------------------------------
-- Anti-bloat : ces tables ont une CHURN élevée (insert massif + purge). Sans
-- autovacuum agressif, l'espace disque ne se réutilise pas (cf. system_alerts :
-- 271 lignes vivantes / 6 776 mortes = 17 Mo de bloat). On rend l'autovacuum
-- plus fréquent pour qu'il suive le rythme des DELETE.
-- ---------------------------------------------------------------------------
ALTER TABLE public.core_feature_health_events
  SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.05);
ALTER TABLE public.job_execution_log
  SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.05);
ALTER TABLE public.fx_collection_log
  SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.05);
ALTER TABLE public.monitoring_events
  SET (autovacuum_vacuum_scale_factor = 0.05);
ALTER TABLE public.system_metrics
  SET (autovacuum_vacuum_scale_factor = 0.05);
ALTER TABLE public.system_alerts
  SET (autovacuum_vacuum_scale_factor = 0.02);

-- NB : VACUUM FULL public.system_alerts; est exécuté HORS migration (ne peut pas
-- tourner dans une transaction). Récupère les 17 Mo de bloat immédiatement.
