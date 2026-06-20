-- Table pour les paiements Stripe
CREATE TABLE IF NOT EXISTS public.stripe_payments (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID,
  payment_intent_id TEXT UNIQUE,
  amount NUMERIC NOT NULL,
  currency TEXT DEFAULT 'GNF',
  status TEXT DEFAULT 'pending',
  order_id TEXT,
  metadata JSONB,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.stripe_payments ENABLE ROW LEVEL SECURITY;

-- Policies for stripe_payments
CREATE POLICY "Users can view own stripe payments"
ON public.stripe_payments
FOR SELECT
USING (auth.uid() = user_id);

CREATE POLICY "Service role can insert stripe payments"
ON public.stripe_payments
FOR INSERT
WITH CHECK (true);

CREATE POLICY "Service role can update stripe payments"
ON public.stripe_payments
FOR UPDATE
USING (true);

-- Index for faster lookups
CREATE INDEX IF NOT EXISTS idx_stripe_payments_user ON public.stripe_payments(user_id);
CREATE INDEX IF NOT EXISTS idx_stripe_payments_intent ON public.stripe_payments(payment_intent_id);

-- Trigger for updated_at
CREATE OR REPLACE TRIGGER update_stripe_payments_updated_at
BEFORE UPDATE ON public.stripe_payments
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();