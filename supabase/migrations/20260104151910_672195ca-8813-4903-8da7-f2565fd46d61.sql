-- Table de configuration Stripe
CREATE TABLE IF NOT EXISTS public.stripe_config (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  stripe_publishable_key TEXT NOT NULL,
  stripe_secret_key TEXT,
  platform_commission_rate NUMERIC(5,2) NOT NULL DEFAULT 5.00,
  currency TEXT NOT NULL DEFAULT 'GNF',
  is_test_mode BOOLEAN NOT NULL DEFAULT true,
  webhook_secret TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.stripe_config ENABLE ROW LEVEL SECURITY;

-- Policy: Only admins can view config
CREATE POLICY "Admins can view stripe config" ON public.stripe_config
FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM public.profiles 
    WHERE id = auth.uid() AND role IN ('admin', 'ceo')
  )
);

-- Table des transactions Stripe
CREATE TABLE IF NOT EXISTS public.stripe_transactions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  stripe_payment_intent_id TEXT NOT NULL UNIQUE,
  buyer_id UUID NOT NULL,
  seller_id UUID NOT NULL,
  amount BIGINT NOT NULL,
  currency TEXT NOT NULL DEFAULT 'GNF',
  commission_rate NUMERIC(5,2) NOT NULL DEFAULT 5.00,
  commission_amount BIGINT NOT NULL DEFAULT 0,
  seller_net_amount BIGINT NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'PENDING',
  order_id TEXT,
  service_id TEXT,
  product_id TEXT,
  payment_method TEXT DEFAULT 'card',
  payment_intent_id TEXT,
  metadata JSONB DEFAULT '{}',
  error_message TEXT,
  paid_at TIMESTAMPTZ,
  refunded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.stripe_transactions ENABLE ROW LEVEL SECURITY;

-- Policies
CREATE POLICY "Users can view their own transactions" ON public.stripe_transactions
FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

CREATE POLICY "System can insert transactions" ON public.stripe_transactions
FOR INSERT WITH CHECK (true);

CREATE POLICY "System can update transactions" ON public.stripe_transactions
FOR UPDATE USING (true);

-- Insert default Stripe config (test mode)
INSERT INTO public.stripe_config (
  stripe_publishable_key,
  platform_commission_rate,
  currency,
  is_test_mode
) VALUES (
  'pk_test_51OGLDuHblsHwcXjqGnrNzrfrj3e1QhfqxKdxKjqVIvjYzlwxB8XCdZTnqfxB1LZxK8vKMqB9v6HzfQ5pQVrq5zqB00mNpYfJpP',
  5.00,
  'GNF',
  true
) ON CONFLICT DO NOTHING;

-- Add index for faster queries
CREATE INDEX IF NOT EXISTS idx_stripe_transactions_buyer ON public.stripe_transactions(buyer_id);
CREATE INDEX IF NOT EXISTS idx_stripe_transactions_seller ON public.stripe_transactions(seller_id);
CREATE INDEX IF NOT EXISTS idx_stripe_transactions_status ON public.stripe_transactions(status);
CREATE INDEX IF NOT EXISTS idx_stripe_transactions_payment_intent ON public.stripe_transactions(stripe_payment_intent_id);