
-- Table for PayPal webhook event logs (audit trail)
CREATE TABLE IF NOT EXISTS public.paypal_webhook_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id TEXT NOT NULL UNIQUE,
  event_type TEXT NOT NULL,
  resource_type TEXT,
  resource_id TEXT,
  summary TEXT,
  paypal_order_id TEXT,
  transmission_id TEXT,
  transmission_time TIMESTAMPTZ,
  signature_verified BOOLEAN NOT NULL DEFAULT false,
  processing_status TEXT NOT NULL DEFAULT 'received' CHECK (processing_status IN ('received', 'verified', 'processed', 'failed', 'ignored')),
  processing_error TEXT,
  raw_payload JSONB NOT NULL,
  metadata JSONB,
  related_user_id UUID,
  related_transaction_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  processed_at TIMESTAMPTZ
);

-- Index for fast lookups
CREATE INDEX IF NOT EXISTS idx_paypal_webhook_event_type ON public.paypal_webhook_events(event_type);
CREATE INDEX IF NOT EXISTS idx_paypal_webhook_order_id ON public.paypal_webhook_events(paypal_order_id);
CREATE INDEX IF NOT EXISTS idx_paypal_webhook_status ON public.paypal_webhook_events(processing_status);
CREATE INDEX IF NOT EXISTS idx_paypal_webhook_created ON public.paypal_webhook_events(created_at DESC);

-- RLS: only service role can insert/read (via edge functions)
ALTER TABLE public.paypal_webhook_events ENABLE ROW LEVEL SECURITY;

-- Admin read policy
CREATE POLICY "Admin can read webhook events" ON public.paypal_webhook_events
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'
  ));
