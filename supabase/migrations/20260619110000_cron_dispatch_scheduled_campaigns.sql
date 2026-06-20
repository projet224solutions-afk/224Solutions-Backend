-- ============================================================================
-- ⏰ CRON — Envoi automatique des campagnes PROGRAMMÉES.
--
-- PROBLÈME : le backend tourne en Vercel serverless → le scheduler in-process
-- (`setInterval` de jobQueue) ne s'exécute JAMAIS en prod. Une campagne créée avec
-- `scheduled_at` restait donc bloquée en status='scheduled' indéfiniment.
--
-- SOLUTION : pg_cron appelle chaque minute, via pg_net, l'endpoint backend sécurisé
-- POST /api/campaigns/cron/dispatch-scheduled (auth `x-internal-api-key`), qui lance
-- `dispatchDueScheduledCampaigns` (claim atomique par campagne → zéro double-envoi,
-- safe même si plusieurs déclencheurs se chevauchent).
--
-- ⚙️ CONFIGURATION REQUISE (Supabase → Vault, mêmes secrets que les notifications) :
--    • BACKEND_URL       = URL publique du backend Node (ex: https://api.224solution.net)
--    • INTERNAL_API_KEY  = même valeur que la variable d'env backend INTERNAL_API_KEY
--   Sans ces secrets (ou s'ils sont vides), le cron ne fait RIEN (sortie propre).
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE OR REPLACE FUNCTION public.trigger_scheduled_campaign_dispatch()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_backend_url  text;
  v_internal_key text;
BEGIN
  -- Secrets depuis Vault. Si Vault/secret absent → sortie propre (aucun envoi).
  BEGIN
    SELECT decrypted_secret INTO v_backend_url  FROM vault.decrypted_secrets WHERE name = 'BACKEND_URL' LIMIT 1;
    SELECT decrypted_secret INTO v_internal_key FROM vault.decrypted_secrets WHERE name = 'INTERNAL_API_KEY' LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    RETURN;
  END;

  IF v_backend_url IS NULL OR v_internal_key IS NULL
     OR length(trim(v_backend_url)) = 0 OR length(trim(v_internal_key)) = 0 THEN
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := rtrim(v_backend_url, '/') || '/api/campaigns/cron/dispatch-scheduled',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-internal-api-key', v_internal_key
    ),
    body := '{}'::jsonb
  );
EXCEPTION WHEN OTHERS THEN
  -- Ne jamais faire échouer le cron.
  RAISE WARNING '[campaign-cron] échec déclencheur: %', SQLERRM;
END;
$$;

-- Fonction privilégiée : réservée au cron / service_role (jamais exposée à anon).
REVOKE EXECUTE ON FUNCTION public.trigger_scheduled_campaign_dispatch() FROM PUBLIC;

-- Planification idempotente : toutes les minutes.
DO $do$
DECLARE
  v_job_id integer;
BEGIN
  SELECT jobid INTO v_job_id FROM cron.job WHERE jobname = 'campaigns-dispatch-scheduled' LIMIT 1;
  IF v_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_job_id);
  END IF;

  PERFORM cron.schedule(
    'campaigns-dispatch-scheduled',
    '* * * * *',
    $job$ SELECT public.trigger_scheduled_campaign_dispatch(); $job$
  );
END;
$do$;

SELECT 'Cron campaigns-dispatch-scheduled posé (chaque minute). Configurer BACKEND_URL + INTERNAL_API_KEY dans Vault pour activer.' AS status;
