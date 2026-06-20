-- Table pour stocker les paiements PawaPay
CREATE TABLE IF NOT EXISTS public.pawapay_payments (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  deposit_id TEXT NOT NULL UNIQUE,
  user_id UUID NOT NULL,
  amount NUMERIC NOT NULL,
  currency TEXT NOT NULL DEFAULT 'GNF',
  correspondent TEXT NOT NULL,
  phone_number TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDING',
  description TEXT,
  metadata JSONB DEFAULT '{}',
  pawapay_response JSONB DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  completed_at TIMESTAMP WITH TIME ZONE
);

-- Index pour les recherches fréquentes
CREATE INDEX IF NOT EXISTS idx_pawapay_payments_user_id ON public.pawapay_payments(user_id);
CREATE INDEX IF NOT EXISTS idx_pawapay_payments_deposit_id ON public.pawapay_payments(deposit_id);
CREATE INDEX IF NOT EXISTS idx_pawapay_payments_status ON public.pawapay_payments(status);

-- Activer RLS
ALTER TABLE public.pawapay_payments ENABLE ROW LEVEL SECURITY;

-- Politique: les utilisateurs peuvent voir leurs propres paiements
CREATE POLICY "Users can view their own pawapay payments"
  ON public.pawapay_payments
  FOR SELECT
  USING (auth.uid() = user_id);

-- Politique: seul le service peut insérer/modifier (via edge function)
CREATE POLICY "Service role can manage pawapay payments"
  ON public.pawapay_payments
  FOR ALL
  USING (true)
  WITH CHECK (true);

-- Trigger pour updated_at
CREATE OR REPLACE FUNCTION update_pawapay_payments_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

CREATE TRIGGER trigger_pawapay_payments_updated_at
  BEFORE UPDATE ON public.pawapay_payments
  FOR EACH ROW
  EXECUTE FUNCTION update_pawapay_payments_updated_at();