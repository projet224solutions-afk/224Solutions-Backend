-- ============================================
-- 1. TABLE: vendor_credit_sales - Ventes à crédit
-- ============================================
CREATE TABLE IF NOT EXISTS public.vendor_credit_sales (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  order_number TEXT NOT NULL,
  customer_name TEXT NOT NULL,
  customer_phone TEXT,
  customer_email TEXT,
  items JSONB NOT NULL DEFAULT '[]',
  subtotal NUMERIC(15,2) NOT NULL DEFAULT 0,
  tax NUMERIC(15,2) NOT NULL DEFAULT 0,
  total NUMERIC(15,2) NOT NULL DEFAULT 0,
  paid_amount NUMERIC(15,2) NOT NULL DEFAULT 0,
  remaining_amount NUMERIC(15,2) NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'partial', 'paid', 'overdue')),
  due_date TIMESTAMP WITH TIME ZONE NOT NULL,
  notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Index pour performance
CREATE INDEX idx_vendor_credit_sales_vendor ON public.vendor_credit_sales(vendor_id);
CREATE INDEX idx_vendor_credit_sales_status ON public.vendor_credit_sales(status);
CREATE UNIQUE INDEX idx_vendor_credit_sales_order ON public.vendor_credit_sales(order_number);

-- RLS
ALTER TABLE public.vendor_credit_sales ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Vendors can view their credit sales" ON public.vendor_credit_sales
  FOR SELECT USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

CREATE POLICY "Vendors can create credit sales" ON public.vendor_credit_sales
  FOR INSERT WITH CHECK (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

CREATE POLICY "Vendors can update their credit sales" ON public.vendor_credit_sales
  FOR UPDATE USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

CREATE POLICY "Vendors can delete their credit sales" ON public.vendor_credit_sales
  FOR DELETE USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

-- ============================================
-- 2. TABLE: credit_sale_payments - Historique paiements crédit
-- ============================================
CREATE TABLE IF NOT EXISTS public.credit_sale_payments (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  credit_sale_id UUID NOT NULL REFERENCES public.vendor_credit_sales(id) ON DELETE CASCADE,
  amount NUMERIC(15,2) NOT NULL,
  payment_method TEXT NOT NULL DEFAULT 'cash',
  payment_account TEXT,
  notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_credit_sale_payments_sale ON public.credit_sale_payments(credit_sale_id);

ALTER TABLE public.credit_sale_payments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Vendors can view their credit payments" ON public.credit_sale_payments
  FOR SELECT USING (credit_sale_id IN (
    SELECT id FROM vendor_credit_sales WHERE vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  ));

CREATE POLICY "Vendors can create credit payments" ON public.credit_sale_payments
  FOR INSERT WITH CHECK (credit_sale_id IN (
    SELECT id FROM vendor_credit_sales WHERE vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  ));

-- ============================================
-- 3. TABLE: vendor_collection_accounts - Comptes d'encaissement
-- ============================================
CREATE TABLE IF NOT EXISTS public.vendor_collection_accounts (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  account_name TEXT NOT NULL,
  account_type TEXT NOT NULL CHECK (account_type IN ('cash', 'orange_money', 'mtn_money', 'bank', 'other')),
  account_number TEXT,
  balance NUMERIC(15,2) NOT NULL DEFAULT 0,
  is_default BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_vendor_collection_accounts_vendor ON public.vendor_collection_accounts(vendor_id);

ALTER TABLE public.vendor_collection_accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Vendors can manage their collection accounts" ON public.vendor_collection_accounts
  FOR ALL USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

-- ============================================
-- 4. TABLE: vendor_account_transactions - Transactions comptes
-- ============================================
CREATE TABLE IF NOT EXISTS public.vendor_account_transactions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES public.vendor_collection_accounts(id) ON DELETE CASCADE,
  transaction_type TEXT NOT NULL CHECK (transaction_type IN ('deposit', 'withdrawal', 'transfer', 'sale', 'expense')),
  amount NUMERIC(15,2) NOT NULL,
  balance_before NUMERIC(15,2) NOT NULL,
  balance_after NUMERIC(15,2) NOT NULL,
  reference_type TEXT,
  reference_id UUID,
  description TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_vendor_account_transactions_account ON public.vendor_account_transactions(account_id);
CREATE INDEX idx_vendor_account_transactions_date ON public.vendor_account_transactions(created_at);

ALTER TABLE public.vendor_account_transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Vendors can view their account transactions" ON public.vendor_account_transactions
  FOR SELECT USING (account_id IN (
    SELECT id FROM vendor_collection_accounts WHERE vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  ));

CREATE POLICY "Vendors can create account transactions" ON public.vendor_account_transactions
  FOR INSERT WITH CHECK (account_id IN (
    SELECT id FROM vendor_collection_accounts WHERE vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  ));

-- ============================================
-- 5. TABLE: stock_adjustments - Ajustements stock (incidents)
-- ============================================
CREATE TABLE IF NOT EXISTS public.stock_adjustments (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  warehouse_id UUID REFERENCES public.warehouses(id),
  adjustment_type TEXT NOT NULL CHECK (adjustment_type IN ('breakage', 'theft', 'expiration', 'correction', 'return', 'other')),
  quantity_before INTEGER NOT NULL,
  quantity_adjusted INTEGER NOT NULL,
  quantity_after INTEGER NOT NULL,
  reason TEXT NOT NULL,
  valuation_method TEXT DEFAULT 'fifo' CHECK (valuation_method IN ('fifo', 'lifo', 'average')),
  unit_cost NUMERIC(15,2),
  total_cost NUMERIC(15,2),
  approved_by UUID,
  approved_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_stock_adjustments_vendor ON public.stock_adjustments(vendor_id);
CREATE INDEX idx_stock_adjustments_product ON public.stock_adjustments(product_id);

ALTER TABLE public.stock_adjustments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Vendors can manage stock adjustments" ON public.stock_adjustments
  FOR ALL USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

-- ============================================
-- 6. TABLE: installment_plans - Paiements échelonnés
-- ============================================
CREATE TABLE IF NOT EXISTS public.installment_plans (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  order_id UUID REFERENCES public.orders(id),
  credit_sale_id UUID REFERENCES public.vendor_credit_sales(id),
  customer_name TEXT NOT NULL,
  customer_phone TEXT,
  total_amount NUMERIC(15,2) NOT NULL,
  down_payment NUMERIC(15,2) DEFAULT 0,
  remaining_amount NUMERIC(15,2) NOT NULL,
  number_of_installments INTEGER NOT NULL,
  installment_amount NUMERIC(15,2) NOT NULL,
  frequency TEXT NOT NULL DEFAULT 'monthly' CHECK (frequency IN ('weekly', 'biweekly', 'monthly')),
  start_date DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed', 'defaulted', 'cancelled')),
  notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_installment_plans_vendor ON public.installment_plans(vendor_id);
CREATE INDEX idx_installment_plans_status ON public.installment_plans(status);

ALTER TABLE public.installment_plans ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Vendors can manage installment plans" ON public.installment_plans
  FOR ALL USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

-- ============================================
-- 7. TABLE: installment_payments - Versements échéancier
-- ============================================
CREATE TABLE IF NOT EXISTS public.installment_payments (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  plan_id UUID NOT NULL REFERENCES public.installment_plans(id) ON DELETE CASCADE,
  installment_number INTEGER NOT NULL,
  due_date DATE NOT NULL,
  amount_due NUMERIC(15,2) NOT NULL,
  amount_paid NUMERIC(15,2) DEFAULT 0,
  payment_date DATE,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid', 'partial', 'overdue')),
  payment_method TEXT,
  notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_installment_payments_plan ON public.installment_payments(plan_id);
CREATE INDEX idx_installment_payments_status ON public.installment_payments(status);

ALTER TABLE public.installment_payments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Vendors can manage installment payments" ON public.installment_payments
  FOR SELECT USING (plan_id IN (
    SELECT id FROM installment_plans WHERE vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  ));

CREATE POLICY "Vendors can create installment payments" ON public.installment_payments
  FOR INSERT WITH CHECK (plan_id IN (
    SELECT id FROM installment_plans WHERE vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  ));

CREATE POLICY "Vendors can update installment payments" ON public.installment_payments
  FOR UPDATE USING (plan_id IN (
    SELECT id FROM installment_plans WHERE vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  ));

-- ============================================
-- 8. TABLE: grouped_sales - Ventes groupées
-- ============================================
CREATE TABLE IF NOT EXISTS public.grouped_sales (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  group_name TEXT NOT NULL,
  customer_name TEXT NOT NULL,
  customer_phone TEXT,
  items JSONB NOT NULL DEFAULT '[]',
  subtotal NUMERIC(15,2) NOT NULL DEFAULT 0,
  discount_type TEXT CHECK (discount_type IN ('percentage', 'fixed')),
  discount_value NUMERIC(15,2) DEFAULT 0,
  discount_amount NUMERIC(15,2) DEFAULT 0,
  total NUMERIC(15,2) NOT NULL DEFAULT 0,
  payment_method TEXT NOT NULL DEFAULT 'cash',
  payment_account_id UUID REFERENCES public.vendor_collection_accounts(id),
  status TEXT NOT NULL DEFAULT 'completed' CHECK (status IN ('pending', 'completed', 'cancelled')),
  notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_grouped_sales_vendor ON public.grouped_sales(vendor_id);

ALTER TABLE public.grouped_sales ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Vendors can manage grouped sales" ON public.grouped_sales
  FOR ALL USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

-- ============================================
-- 9. TABLE: sale_returns - Ventes retournées
-- ============================================
CREATE TABLE IF NOT EXISTS public.sale_returns (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  order_id UUID REFERENCES public.orders(id),
  order_item_id UUID,
  product_id UUID REFERENCES public.products(id),
  quantity_returned INTEGER NOT NULL,
  unit_price NUMERIC(15,2) NOT NULL,
  refund_amount NUMERIC(15,2) NOT NULL,
  return_reason TEXT NOT NULL CHECK (return_reason IN ('defective', 'wrong_item', 'customer_change', 'quality', 'other')),
  return_condition TEXT CHECK (return_condition IN ('resellable', 'damaged', 'destroyed')),
  restock BOOLEAN DEFAULT false,
  refund_method TEXT,
  notes TEXT,
  processed_by UUID,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_sale_returns_vendor ON public.sale_returns(vendor_id);
CREATE INDEX idx_sale_returns_order ON public.sale_returns(order_id);

ALTER TABLE public.sale_returns ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Vendors can manage sale returns" ON public.sale_returns
  FOR ALL USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

-- ============================================
-- 10. TABLE: vendor_promotions - Promotions vendeur
-- ============================================
CREATE TABLE IF NOT EXISTS public.vendor_promotions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  discount_type TEXT NOT NULL CHECK (discount_type IN ('percentage', 'fixed', 'buy_x_get_y')),
  discount_value NUMERIC(15,2) NOT NULL,
  min_purchase_amount NUMERIC(15,2),
  max_discount_amount NUMERIC(15,2),
  applicable_products JSONB DEFAULT '[]',
  applicable_categories JSONB DEFAULT '[]',
  start_date TIMESTAMP WITH TIME ZONE NOT NULL,
  end_date TIMESTAMP WITH TIME ZONE NOT NULL,
  usage_limit INTEGER,
  usage_count INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  promo_code TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_vendor_promotions_vendor ON public.vendor_promotions(vendor_id);
CREATE INDEX idx_vendor_promotions_active ON public.vendor_promotions(is_active);
CREATE INDEX idx_vendor_promotions_dates ON public.vendor_promotions(start_date, end_date);

ALTER TABLE public.vendor_promotions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Vendors can manage promotions" ON public.vendor_promotions
  FOR ALL USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

-- ============================================
-- 11. Ajouter colonnes contacts aux clients/fournisseurs existants
-- ============================================

-- Ajouter credit_limit et total_debt aux customers si pas déjà présent
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'customers' AND column_name = 'credit_limit') THEN
    ALTER TABLE public.customers ADD COLUMN credit_limit NUMERIC(15,2) DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'customers' AND column_name = 'total_credit') THEN
    ALTER TABLE public.customers ADD COLUMN total_credit NUMERIC(15,2) DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'customers' AND column_name = 'total_debt') THEN
    ALTER TABLE public.customers ADD COLUMN total_debt NUMERIC(15,2) DEFAULT 0;
  END IF;
END $$;

-- ============================================
-- 12. TABLE: contact_statements - Relevés clients/fournisseurs
-- ============================================
CREATE TABLE IF NOT EXISTS public.contact_statements (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  contact_type TEXT NOT NULL CHECK (contact_type IN ('customer', 'supplier')),
  contact_id UUID NOT NULL,
  contact_name TEXT NOT NULL,
  statement_date DATE NOT NULL,
  opening_balance NUMERIC(15,2) NOT NULL DEFAULT 0,
  total_debits NUMERIC(15,2) NOT NULL DEFAULT 0,
  total_credits NUMERIC(15,2) NOT NULL DEFAULT 0,
  closing_balance NUMERIC(15,2) NOT NULL DEFAULT 0,
  transactions JSONB NOT NULL DEFAULT '[]',
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  generated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX idx_contact_statements_vendor ON public.contact_statements(vendor_id);
CREATE INDEX idx_contact_statements_contact ON public.contact_statements(contact_type, contact_id);

ALTER TABLE public.contact_statements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Vendors can manage contact statements" ON public.contact_statements
  FOR ALL USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

-- ============================================
-- 13. Trigger pour mise à jour automatique updated_at
-- ============================================
CREATE OR REPLACE FUNCTION update_vendor_credit_sales_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_vendor_credit_sales ON public.vendor_credit_sales;
CREATE TRIGGER trigger_update_vendor_credit_sales
  BEFORE UPDATE ON public.vendor_credit_sales
  FOR EACH ROW EXECUTE FUNCTION update_vendor_credit_sales_updated_at();

-- ============================================
-- 14. Fonction pour mettre à jour automatiquement les ventes en retard
-- ============================================
CREATE OR REPLACE FUNCTION update_overdue_credit_sales()
RETURNS void AS $$
BEGIN
  UPDATE public.vendor_credit_sales
  SET status = 'overdue'
  WHERE status IN ('pending', 'partial')
    AND due_date < now()
    AND remaining_amount > 0;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 15. Ajouter valuation_method aux warehouses
-- ============================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'warehouses' AND column_name = 'valuation_method') THEN
    ALTER TABLE public.warehouses ADD COLUMN valuation_method TEXT DEFAULT 'fifo' CHECK (valuation_method IN ('fifo', 'lifo', 'average'));
  END IF;
END $$;