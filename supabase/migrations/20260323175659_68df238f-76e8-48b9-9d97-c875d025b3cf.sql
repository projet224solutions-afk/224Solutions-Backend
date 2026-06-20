
-- Enable pg_net if not already
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- Schedule hourly FX collection (every hour at minute 0)
SELECT cron.schedule(
  'african-fx-hourly',
  '0 * * * *',
  $$
  SELECT net.http_post(
    url:='https://uakkxaibujzxdiqzpnpr.supabase.co/functions/v1/african-fx-collect',
    headers:='{"Content-Type": "application/json", "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVha2t4YWlidWp6eGRpcXpwbnByIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTkwMDA2NTcsImV4cCI6MjA3NDU3NjY1N30.kqYNdg-73BTP0Yht7kid-EZu2APg9qw-b_KW9z5hJbM"}'::jsonb,
    body:='{"source": "cron_hourly"}'::jsonb
  ) as request_id;
  $$
);
