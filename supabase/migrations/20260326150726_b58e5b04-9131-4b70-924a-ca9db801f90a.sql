-- ================================================================
-- PHASE 6: Webhook journal + monitoring tables
-- ================================================================

-- 1. Webhook event journal (provider-agnostic)
CREATE TABLE IF NOT EXISTS public.webhook_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  webhook_id text NOT NULL,
  provider text NOT NULL DEFAULT 'stripe',
  event_type text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  processing_status text NOT NULL DEFAULT 'received',
  processed_at timestamptz,
  error_message text,
  retry_count int NOT NULL DEFAULT 0,
  idempotency_hash text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_webhook_events_unique 
  ON public.webhook_events(provider, webhook_id);

CREATE INDEX IF NOT EXISTS idx_webhook_events_status 
  ON public.webhook_events(processing_status, created_at DESC);

-- 2. Job execution log for async job monitoring
CREATE TABLE IF NOT EXISTS public.job_execution_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_name text NOT NULL,
  queue_name text NOT NULL DEFAULT 'default',
  status text NOT NULL DEFAULT 'started',
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  duration_ms int,
  error_message text,
  metadata jsonb DEFAULT '{}'::jsonb,
  attempt int NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_job_exec_log_name 
  ON public.job_execution_log(job_name, created_at DESC);

-- 3. Security audit trail for sensitive operations
CREATE TABLE IF NOT EXISTS public.security_audit_trail (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id text,
  actor_type text NOT NULL DEFAULT 'user',
  action text NOT NULL,
  resource_type text NOT NULL,
  resource_id text,
  ip_address text,
  user_agent text,
  metadata jsonb DEFAULT '{}'::jsonb,
  risk_level text DEFAULT 'low',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_security_audit_actor 
  ON public.security_audit_trail(actor_id, created_at DESC);

-- 4. System metrics snapshot
CREATE TABLE IF NOT EXISTS public.system_metrics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  metric_name text NOT NULL,
  metric_value numeric NOT NULL,
  labels jsonb DEFAULT '{}'::jsonb,
  recorded_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_system_metrics_name 
  ON public.system_metrics(metric_name, recorded_at DESC);

-- Enable RLS (service_role only access)
ALTER TABLE public.webhook_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.job_execution_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.security_audit_trail ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_metrics ENABLE ROW LEVEL SECURITY;

CREATE POLICY "service_role_webhook_events" ON public.webhook_events
  FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "service_role_job_log" ON public.job_execution_log
  FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "service_role_security_audit" ON public.security_audit_trail
  FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "service_role_system_metrics" ON public.system_metrics
  FOR ALL TO service_role USING (true) WITH CHECK (true);