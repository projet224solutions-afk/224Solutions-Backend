-- Create moneroo_payments table
CREATE TABLE IF NOT EXISTS public.moneroo_payments (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  payment_id TEXT NOT NULL UNIQUE,
  amount DECIMAL(10, 2) NOT NULL,
  currency TEXT NOT NULL DEFAULT 'GNF',
  status TEXT NOT NULL DEFAULT 'pending',
  checkout_url TEXT,
  metadata JSONB,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Create index for faster queries
CREATE INDEX idx_moneroo_payments_user_id ON public.moneroo_payments(user_id);
CREATE INDEX idx_moneroo_payments_payment_id ON public.moneroo_payments(payment_id);
CREATE INDEX idx_moneroo_payments_status ON public.moneroo_payments(status);

-- Enable Row Level Security
ALTER TABLE public.moneroo_payments ENABLE ROW LEVEL SECURITY;

-- Create policies
CREATE POLICY "Users can view their own payments"
  ON public.moneroo_payments
  FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own payments"
  ON public.moneroo_payments
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "System can update payments"
  ON public.moneroo_payments
  FOR UPDATE
  USING (true);

-- Create trigger for updated_at
CREATE OR REPLACE FUNCTION public.update_moneroo_payments_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

CREATE TRIGGER trigger_update_moneroo_payments_updated_at
  BEFORE UPDATE ON public.moneroo_payments
  FOR EACH ROW
  EXECUTE FUNCTION public.update_moneroo_payments_updated_at();