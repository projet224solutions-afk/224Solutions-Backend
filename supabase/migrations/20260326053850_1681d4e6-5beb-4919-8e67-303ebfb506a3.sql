SELECT cron.schedule(
  'production-cron-jobs',
  '*/15 * * * *',
  $$
  SELECT
    net.http_post(
      url:='https://uakkxaibujzxdiqzpnpr.supabase.co/functions/v1/production-cron-jobs',
      headers:='{"Content-Type": "application/json", "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVha2t4YWlidWp6eGRpcXpwbnByIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTkwMDA2NTcsImV4cCI6MjA3NDU3NjY1N30.kqYNdg-73BTP0Yht7kid-EZu2APg9qw-b_KW9z5hJbM"}'::jsonb,
      body:=concat('{"time": "', now(), '"}')::jsonb
    ) AS request_id;
  $$
);