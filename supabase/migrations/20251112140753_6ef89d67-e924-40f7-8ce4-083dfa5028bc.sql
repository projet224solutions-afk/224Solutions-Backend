-- Add Stripe integration columns to escrow_transactions
ALTER TABLE public.escrow_transactions 
  ADD COLUMN IF NOT EXISTS stripe_payment_intent_id TEXT,
  ADD COLUMN IF NOT EXISTS stripe_charge_id TEXT,
  ADD COLUMN IF NOT EXISTS stripe_refund_id TEXT;

-- Create index for faster Stripe lookups
CREATE INDEX IF NOT EXISTS idx_escrow_stripe_pi ON public.escrow_transactions(stripe_payment_intent_id);

-- Add comments for documentation
COMMENT ON COLUMN public.escrow_transactions.stripe_payment_intent_id IS 'Stripe PaymentIntent ID for secure fund holding';
COMMENT ON COLUMN public.escrow_transactions.stripe_charge_id IS 'Stripe Charge ID after capture';
COMMENT ON COLUMN public.escrow_transactions.stripe_refund_id IS 'Stripe Refund ID if refunded';
