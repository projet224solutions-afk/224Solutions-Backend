-- Table pour stocker les coûts fixes mensuels du vendeur (loyer, abonnement, etc.)
CREATE TABLE IF NOT EXISTS public.vendor_fixed_costs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  cost_type VARCHAR(50) NOT NULL CHECK (cost_type IN ('loyer', 'abonnement', 'salaires', 'electricite', 'internet', 'assurance', 'autre')),
  label VARCHAR(255) NOT NULL,
  amount NUMERIC NOT NULL DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Index pour performance
CREATE INDEX IF NOT EXISTS idx_vendor_fixed_costs_vendor ON public.vendor_fixed_costs(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_fixed_costs_type ON public.vendor_fixed_costs(cost_type);

-- RLS
ALTER TABLE public.vendor_fixed_costs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Vendors can view their own fixed costs"
ON public.vendor_fixed_costs FOR SELECT
USING (vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()));

CREATE POLICY "Vendors can insert their own fixed costs"
ON public.vendor_fixed_costs FOR INSERT
WITH CHECK (vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()));

CREATE POLICY "Vendors can update their own fixed costs"
ON public.vendor_fixed_costs FOR UPDATE
USING (vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()));

CREATE POLICY "Vendors can delete their own fixed costs"
ON public.vendor_fixed_costs FOR DELETE
USING (vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()));

-- Trigger pour updated_at
CREATE OR REPLACE TRIGGER update_vendor_fixed_costs_updated_at
BEFORE UPDATE ON public.vendor_fixed_costs
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();