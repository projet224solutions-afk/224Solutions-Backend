-- Table pour gérer les dettes clients
CREATE TABLE IF NOT EXISTS public.debts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  customer_name TEXT NOT NULL,
  customer_phone TEXT NOT NULL,
  customer_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  total_amount NUMERIC NOT NULL CHECK (total_amount > 0),
  paid_amount NUMERIC NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
  remaining_amount NUMERIC NOT NULL CHECK (remaining_amount >= 0),
  minimum_installment NUMERIC NOT NULL CHECK (minimum_installment > 0),
  description TEXT,
  due_date DATE,
  status TEXT NOT NULL DEFAULT 'in_progress' CHECK (status IN ('in_progress', 'paid', 'overdue', 'cancelled')),
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Table pour les paiements de tranches
CREATE TABLE IF NOT EXISTS public.debt_payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  debt_id UUID NOT NULL REFERENCES public.debts(id) ON DELETE CASCADE,
  amount NUMERIC NOT NULL CHECK (amount > 0),
  payment_method TEXT NOT NULL CHECK (payment_method IN ('cash', 'wallet', 'mobile_money', 'card')),
  comment TEXT,
  paid_by UUID REFERENCES auth.users(id),
  recorded_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_debts_vendor_id ON public.debts(vendor_id);
CREATE INDEX IF NOT EXISTS idx_debts_customer_id ON public.debts(customer_id);
CREATE INDEX IF NOT EXISTS idx_debts_status ON public.debts(status);
CREATE INDEX IF NOT EXISTS idx_debt_payments_debt_id ON public.debt_payments(debt_id);

-- Enable RLS
ALTER TABLE public.debts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.debt_payments ENABLE ROW LEVEL SECURITY;

-- Policies pour debts
CREATE POLICY "Vendors can view their own debts"
ON public.debts FOR SELECT
USING (
  vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  OR has_role(auth.uid(), 'admin'::user_role)
);

CREATE POLICY "Vendors can create debts"
ON public.debts FOR INSERT
WITH CHECK (
  vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
);

CREATE POLICY "Vendors can update their own debts"
ON public.debts FOR UPDATE
USING (
  vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  OR has_role(auth.uid(), 'admin'::user_role)
);

-- Policies pour debt_payments
CREATE POLICY "Users can view payments for their debts"
ON public.debt_payments FOR SELECT
USING (
  debt_id IN (
    SELECT id FROM public.debts WHERE 
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    OR customer_id = auth.uid()
    OR has_role(auth.uid(), 'admin'::user_role)
  )
);

CREATE POLICY "Vendors can create payments"
ON public.debt_payments FOR INSERT
WITH CHECK (
  debt_id IN (
    SELECT id FROM public.debts WHERE 
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  )
);

-- Fonction pour mettre à jour automatiquement les montants
CREATE OR REPLACE FUNCTION public.update_debt_amounts()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE public.debts
  SET 
    paid_amount = (
      SELECT COALESCE(SUM(amount), 0) 
      FROM public.debt_payments 
      WHERE debt_id = NEW.debt_id
    ),
    remaining_amount = total_amount - (
      SELECT COALESCE(SUM(amount), 0) 
      FROM public.debt_payments 
      WHERE debt_id = NEW.debt_id
    ),
    status = CASE 
      WHEN total_amount - (
        SELECT COALESCE(SUM(amount), 0) 
        FROM public.debt_payments 
        WHERE debt_id = NEW.debt_id
      ) <= 0 THEN 'paid'
      WHEN due_date < CURRENT_DATE AND total_amount - (
        SELECT COALESCE(SUM(amount), 0) 
        FROM public.debt_payments 
        WHERE debt_id = NEW.debt_id
      ) > 0 THEN 'overdue'
      ELSE 'in_progress'
    END,
    updated_at = now()
  WHERE id = NEW.debt_id;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Trigger pour mettre à jour les montants après chaque paiement
CREATE TRIGGER update_debt_amounts_trigger
AFTER INSERT ON public.debt_payments
FOR EACH ROW
EXECUTE FUNCTION public.update_debt_amounts();

-- Fonction pour vérifier les dettes en retard
CREATE OR REPLACE FUNCTION public.check_overdue_debts()
RETURNS void AS $$
BEGIN
  UPDATE public.debts
  SET status = 'overdue', updated_at = now()
  WHERE due_date < CURRENT_DATE 
    AND remaining_amount > 0 
    AND status = 'in_progress';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;