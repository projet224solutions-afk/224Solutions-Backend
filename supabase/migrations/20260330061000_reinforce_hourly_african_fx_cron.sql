-- Reinforce hourly FX collection schedule (idempotent)
-- Ensures african-fx-collect is executed every hour.

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $do$
DECLARE
  v_job_id integer;
BEGIN
  SELECT jobid
  INTO v_job_id
  FROM cron.job
  WHERE jobname = 'african-fx-hourly'
  LIMIT 1;

  IF v_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_job_id);
  END IF;

  PERFORM cron.schedule(
    'african-fx-hourly',
    '0 * * * *',
    $job$
    SELECT net.http_post(
      url:='https://uakkxaibujzxdiqzpnpr.supabase.co/functions/v1/african-fx-collect',
      headers:='{"Content-Type": "application/json", "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVha2t4YWlidWp6eGRpcXpwbnByIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTkwMDA2NTcsImV4cCI6MjA3NDU3NjY1N30.kqYNdg-73BTP0Yht7kid-EZu2APg9qw-b_KW9z5hJbM"}'::jsonb,
      body:='{"source": "cron_hourly"}'::jsonb
    ) as request_id;
    $job$
  );
END;
$do$;