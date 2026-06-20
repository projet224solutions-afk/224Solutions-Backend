-- Add payment_intent_id column to orders table
-- Required by create_order_core RPC which inserts this column
-- Missing from original migration 20260326182125

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS payment_intent_id TEXT;

-- Index for webhook lookups (find order by Stripe PaymentIntent ID)
CREATE INDEX IF NOT EXISTS idx_orders_payment_intent_id
  ON public.orders(payment_intent_id)
  WHERE payment_intent_id IS NOT NULL;

COMMENT ON COLUMN public.orders.payment_intent_id IS 'Stripe PaymentIntent ID for card payments and escrow tracking';
