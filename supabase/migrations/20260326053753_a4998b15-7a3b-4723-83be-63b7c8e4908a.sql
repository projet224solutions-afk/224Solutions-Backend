-- Enable required extensions for scheduled jobs
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- Create pos_stock_reconciliation table for POS stock retry
CREATE TABLE IF NOT EXISTS public.pos_stock_reconciliation (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id uuid NOT NULL,
  pos_sale_id uuid NOT NULL,
  product_id uuid NOT NULL,
  expected_decrement integer NOT NULL,
  status text DEFAULT 'pending',
  error_message text,
  retry_count integer DEFAULT 0,
  max_retries integer DEFAULT 5,
  last_retry_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE public.pos_stock_reconciliation ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role only" ON public.pos_stock_reconciliation
  FOR ALL USING (false);

CREATE INDEX IF NOT EXISTS idx_pos_reconciliation_pending
  ON public.pos_stock_reconciliation(status) WHERE status = 'pending';

-- Ensure idempotency_keys has required columns
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='idempotency_keys' AND column_name='user_id') THEN
    ALTER TABLE public.idempotency_keys ADD COLUMN user_id uuid;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='idempotency_keys' AND column_name='payload_hash') THEN
    ALTER TABLE public.idempotency_keys ADD COLUMN payload_hash text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='idempotency_keys' AND column_name='status') THEN
    ALTER TABLE public.idempotency_keys ADD COLUMN status text DEFAULT 'processing';
  END IF;
END$$;