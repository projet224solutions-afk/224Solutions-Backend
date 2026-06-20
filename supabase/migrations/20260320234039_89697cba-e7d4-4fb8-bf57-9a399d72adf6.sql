-- Task Queue for async operations (payments, notifications, heavy computation)
CREATE TABLE IF NOT EXISTS public.task_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_type text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}',
  priority text NOT NULL DEFAULT 'normal',
  status text NOT NULL DEFAULT 'pending',
  scheduled_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  completed_at timestamptz,
  max_retries integer NOT NULL DEFAULT 3,
  retry_count integer NOT NULL DEFAULT 0,
  error_message text,
  last_error_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_task_queue_pending ON public.task_queue (priority, created_at) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_task_queue_status ON public.task_queue (status);
CREATE INDEX IF NOT EXISTS idx_task_queue_scheduled ON public.task_queue (scheduled_at) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_task_queue_type ON public.task_queue (task_type);

CREATE OR REPLACE FUNCTION update_task_queue_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS task_queue_updated ON public.task_queue;
CREATE TRIGGER task_queue_updated
  BEFORE UPDATE ON public.task_queue
  FOR EACH ROW
  EXECUTE FUNCTION update_task_queue_timestamp();

CREATE OR REPLACE FUNCTION get_queue_stats()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT jsonb_build_object(
    'pending', (SELECT count(*) FROM task_queue WHERE status = 'pending'),
    'processing', (SELECT count(*) FROM task_queue WHERE status = 'processing'),
    'completed_today', (SELECT count(*) FROM task_queue WHERE status = 'completed' AND completed_at >= CURRENT_DATE),
    'failed', (SELECT count(*) FROM task_queue WHERE status = 'failed'),
    'avg_processing_ms', (
      SELECT COALESCE(
        EXTRACT(EPOCH FROM AVG(completed_at - started_at)) * 1000, 0
      )::integer
      FROM task_queue 
      WHERE status = 'completed' AND completed_at >= CURRENT_DATE
    )
  );
$$;

ALTER TABLE public.task_queue ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role manages queue"
  ON public.task_queue
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);