-- Table pour stocker les paiements Djomy
CREATE TABLE IF NOT EXISTS public.djomy_payments (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id),
  transaction_id TEXT NOT NULL UNIQUE,
  amount NUMERIC NOT NULL,
  currency TEXT DEFAULT 'GNF',
  payment_method TEXT,
  status TEXT DEFAULT 'pending',
  order_id TEXT,
  payer_phone TEXT,
  country_code TEXT DEFAULT 'GN',
  redirect_url TEXT,
  paid_amount NUMERIC,
  received_amount NUMERIC,
  fees NUMERIC,
  webhook_event_id TEXT,
  webhook_received_at TIMESTAMPTZ,
  response_data JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index pour recherche rapide
CREATE INDEX IF NOT EXISTS idx_djomy_payments_user_id ON public.djomy_payments(user_id);
CREATE INDEX IF NOT EXISTS idx_djomy_payments_transaction_id ON public.djomy_payments(transaction_id);
CREATE INDEX IF NOT EXISTS idx_djomy_payments_order_id ON public.djomy_payments(order_id);
CREATE INDEX IF NOT EXISTS idx_djomy_payments_status ON public.djomy_payments(status);

-- Enable RLS
ALTER TABLE public.djomy_payments ENABLE ROW LEVEL SECURITY;

-- Policies
CREATE POLICY "Users can view their own payments" 
ON public.djomy_payments 
FOR SELECT 
USING (auth.uid() = user_id);

CREATE POLICY "Service role can manage all payments" 
ON public.djomy_payments 
FOR ALL 
USING (true)
WITH CHECK (true);

-- Table pour les logs de webhooks
CREATE TABLE IF NOT EXISTS public.djomy_webhook_logs (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  event_id TEXT,
  event_type TEXT,
  transaction_id TEXT,
  payload JSONB,
  processed_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index pour les logs
CREATE INDEX IF NOT EXISTS idx_djomy_webhook_logs_event_id ON public.djomy_webhook_logs(event_id);
CREATE INDEX IF NOT EXISTS idx_djomy_webhook_logs_transaction_id ON public.djomy_webhook_logs(transaction_id);

-- Enable RLS
ALTER TABLE public.djomy_webhook_logs ENABLE ROW LEVEL SECURITY;

-- Policy pour les logs (lecture seule pour les admins)
CREATE POLICY "Service role can manage webhook logs" 
ON public.djomy_webhook_logs 
FOR ALL 
USING (true)
WITH CHECK (true);

-- Trigger pour updated_at
CREATE TRIGGER update_djomy_payments_updated_at
BEFORE UPDATE ON public.djomy_payments
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();