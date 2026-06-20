-- =====================================================
-- TABLES MANQUANTES POUR LE SYSTÈME VENDEUR OFFLINE
-- 224SOLUTIONS - Ventes et Transactions Fournisseur
-- =====================================================

-- 1. Table des ventes (sales)
CREATE TABLE IF NOT EXISTS public.sales (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  customer_id UUID REFERENCES public.customers(id),
  product_id UUID REFERENCES public.products(id),
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL DEFAULT 1,
  unit_price NUMERIC(12,2) NOT NULL,
  total_amount NUMERIC(12,2) NOT NULL,
  tax_amount NUMERIC(12,2) DEFAULT 0,
  discount_amount NUMERIC(12,2) DEFAULT 0,
  payment_method TEXT DEFAULT 'cash',
  payment_status TEXT DEFAULT 'paid',
  status TEXT DEFAULT 'completed',
  customer_name TEXT,
  customer_phone TEXT,
  notes TEXT,
  metadata JSONB DEFAULT '{}',
  offline_sync BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Index pour les requêtes fréquentes
CREATE INDEX IF NOT EXISTS idx_sales_vendor_id ON public.sales(vendor_id);
CREATE INDEX IF NOT EXISTS idx_sales_created_at ON public.sales(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sales_status ON public.sales(status);

-- 2. Table des transactions fournisseur (vendor_transactions)
CREATE TABLE IF NOT EXISTS public.vendor_transactions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  type TEXT NOT NULL, -- 'sale', 'payment', 'refund', 'commission', 'withdrawal'
  amount NUMERIC(12,2) NOT NULL,
  currency TEXT DEFAULT 'XOF',
  status TEXT DEFAULT 'completed', -- 'pending', 'completed', 'failed', 'cancelled'
  reference TEXT,
  description TEXT,
  related_sale_id UUID REFERENCES public.sales(id),
  payment_method TEXT,
  metadata JSONB DEFAULT '{}',
  offline_sync BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Index pour les requêtes
CREATE INDEX IF NOT EXISTS idx_vendor_transactions_vendor_id ON public.vendor_transactions(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_transactions_type ON public.vendor_transactions(type);
CREATE INDEX IF NOT EXISTS idx_vendor_transactions_created_at ON public.vendor_transactions(created_at DESC);

-- 3. Enable RLS
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_transactions ENABLE ROW LEVEL SECURITY;

-- 4. RLS Policies pour sales
CREATE POLICY "Vendors can view their own sales"
  ON public.sales FOR SELECT
  USING (vendor_id IN (
    SELECT id FROM public.vendors WHERE user_id = auth.uid()
  ));

CREATE POLICY "Vendors can insert their own sales"
  ON public.sales FOR INSERT
  WITH CHECK (vendor_id IN (
    SELECT id FROM public.vendors WHERE user_id = auth.uid()
  ));

CREATE POLICY "Vendors can update their own sales"
  ON public.sales FOR UPDATE
  USING (vendor_id IN (
    SELECT id FROM public.vendors WHERE user_id = auth.uid()
  ));

-- 5. RLS Policies pour vendor_transactions
CREATE POLICY "Vendors can view their own transactions"
  ON public.vendor_transactions FOR SELECT
  USING (vendor_id IN (
    SELECT id FROM public.vendors WHERE user_id = auth.uid()
  ));

CREATE POLICY "Vendors can insert their own transactions"
  ON public.vendor_transactions FOR INSERT
  WITH CHECK (vendor_id IN (
    SELECT id FROM public.vendors WHERE user_id = auth.uid()
  ));

-- 6. Trigger pour updated_at
CREATE OR REPLACE FUNCTION public.update_sales_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_sales_timestamp
  BEFORE UPDATE ON public.sales
  FOR EACH ROW
  EXECUTE FUNCTION public.update_sales_updated_at();

CREATE TRIGGER update_vendor_transactions_timestamp
  BEFORE UPDATE ON public.vendor_transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.update_sales_updated_at();