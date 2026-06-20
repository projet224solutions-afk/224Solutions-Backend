-- =====================================================
-- CORRECTION COMPLÈTE: Tables et Fonctions Manquantes
-- =====================================================

-- 1. CRÉER LA TABLE NOTIFICATIONS
CREATE TABLE IF NOT EXISTS public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title VARCHAR(255) NOT NULL,
  message TEXT NOT NULL,
  type VARCHAR(50) DEFAULT 'info',
  read BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 2. CRÉER LA TABLE EXPENSE_CATEGORIES
CREATE TABLE IF NOT EXISTS public.expense_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name VARCHAR(255) NOT NULL,
  color VARCHAR(50) DEFAULT '#3B82F6',
  icon VARCHAR(50) DEFAULT 'Receipt',
  budget_limit NUMERIC(15,2) DEFAULT 0,
  is_default BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 3. CRÉER LA TABLE VENDOR_EXPENSES
CREATE TABLE IF NOT EXISTS public.vendor_expenses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  category_id UUID REFERENCES public.expense_categories(id) ON DELETE SET NULL,
  amount NUMERIC(15,2) NOT NULL,
  description TEXT,
  expense_date DATE NOT NULL DEFAULT CURRENT_DATE,
  payment_method VARCHAR(50) DEFAULT 'cash',
  receipt_url TEXT,
  status VARCHAR(50) DEFAULT 'pending',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 4. CRÉER LA TABLE EXPENSE_RECEIPTS
CREATE TABLE IF NOT EXISTS public.expense_receipts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  expense_id UUID NOT NULL REFERENCES public.vendor_expenses(id) ON DELETE CASCADE,
  file_url TEXT NOT NULL,
  file_name VARCHAR(255),
  file_size INTEGER,
  mime_type VARCHAR(100),
  uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 5. CRÉER LA TABLE EXPENSE_BUDGETS
CREATE TABLE IF NOT EXISTS public.expense_budgets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  category_id UUID REFERENCES public.expense_categories(id) ON DELETE CASCADE,
  month DATE NOT NULL,
  budget_limit NUMERIC(15,2) NOT NULL,
  spent_amount NUMERIC(15,2) DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE(vendor_id, category_id, month)
);

-- 6. CRÉER LA TABLE EXPENSE_ANALYTICS
CREATE TABLE IF NOT EXISTS public.expense_analytics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  analysis_date DATE NOT NULL DEFAULT CURRENT_DATE,
  total_expenses NUMERIC(15,2) DEFAULT 0,
  category_breakdown JSONB DEFAULT '{}'::JSONB,
  trends JSONB DEFAULT '{}'::JSONB,
  recommendations TEXT[],
  efficiency_score NUMERIC(5,2) DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 7. CRÉER LA TABLE EXPENSE_ALERTS
CREATE TABLE IF NOT EXISTS public.expense_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  alert_type VARCHAR(50) NOT NULL,
  severity VARCHAR(20) DEFAULT 'info',
  title VARCHAR(255) NOT NULL,
  message TEXT NOT NULL,
  is_read BOOLEAN DEFAULT false,
  related_expense_id UUID REFERENCES public.vendor_expenses(id) ON DELETE SET NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- =====================================================
-- ACTIVER RLS SUR TOUTES LES TABLES
-- =====================================================

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_budgets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_analytics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_alerts ENABLE ROW LEVEL SECURITY;

-- =====================================================
-- POLITIQUES RLS
-- =====================================================

-- Notifications
CREATE POLICY "Users can view their own notifications"
  ON public.notifications FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can update their own notifications"
  ON public.notifications FOR UPDATE
  USING (auth.uid() = user_id);

-- Expense Categories
CREATE POLICY "Vendors can manage their categories"
  ON public.expense_categories FOR ALL
  USING (auth.uid() = vendor_id);

-- Vendor Expenses
CREATE POLICY "Vendors can manage their expenses"
  ON public.vendor_expenses FOR ALL
  USING (auth.uid() = vendor_id);

-- Expense Receipts
CREATE POLICY "Vendors can manage receipts for their expenses"
  ON public.expense_receipts FOR ALL
  USING (EXISTS (
    SELECT 1 FROM public.vendor_expenses
    WHERE id = expense_receipts.expense_id
    AND vendor_id = auth.uid()
  ));

-- Expense Budgets
CREATE POLICY "Vendors can manage their budgets"
  ON public.expense_budgets FOR ALL
  USING (auth.uid() = vendor_id);

-- Expense Analytics
CREATE POLICY "Vendors can view their analytics"
  ON public.expense_analytics FOR SELECT
  USING (auth.uid() = vendor_id);

-- Expense Alerts
CREATE POLICY "Vendors can manage their alerts"
  ON public.expense_alerts FOR ALL
  USING (auth.uid() = vendor_id);

-- =====================================================
-- FONCTIONS SQL MANQUANTES
-- =====================================================

-- Fonction: Créer les catégories par défaut pour un vendeur
CREATE OR REPLACE FUNCTION public.create_default_expense_categories(p_vendor_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.expense_categories (vendor_id, name, color, icon, is_default)
  VALUES
    (p_vendor_id, 'Achat de marchandises', '#3B82F6', 'ShoppingCart', true),
    (p_vendor_id, 'Loyer & Charges', '#10B981', 'Home', true),
    (p_vendor_id, 'Salaires & Personnel', '#F59E0B', 'Users', true),
    (p_vendor_id, 'Transport & Livraison', '#8B5CF6', 'Truck', true),
    (p_vendor_id, 'Marketing & Publicité', '#EC4899', 'Megaphone', true),
    (p_vendor_id, 'Équipement & Matériel', '#6366F1', 'Package', true),
    (p_vendor_id, 'Autres dépenses', '#6B7280', 'Receipt', true)
  ON CONFLICT DO NOTHING;
END;
$$;

-- Fonction: Calculer les statistiques de dépenses
CREATE OR REPLACE FUNCTION public.calculate_expense_stats(
  p_vendor_id UUID,
  p_start_date DATE,
  p_end_date DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result JSONB;
  total_amount NUMERIC;
  expense_count INTEGER;
  avg_amount NUMERIC;
BEGIN
  SELECT
    COALESCE(SUM(amount), 0),
    COUNT(*),
    COALESCE(AVG(amount), 0)
  INTO total_amount, expense_count, avg_amount
  FROM public.vendor_expenses
  WHERE vendor_id = p_vendor_id
    AND expense_date BETWEEN p_start_date AND p_end_date;

  result := jsonb_build_object(
    'total_amount', total_amount,
    'expense_count', expense_count,
    'average_amount', avg_amount,
    'period_start', p_start_date,
    'period_end', p_end_date
  );

  RETURN result;
END;
$$;

-- Fonction: Détecter les anomalies de dépenses
CREATE OR REPLACE FUNCTION public.detect_expense_anomalies(p_vendor_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  anomalies JSONB := '[]'::JSONB;
  avg_expense NUMERIC;
  high_expense_threshold NUMERIC;
BEGIN
  -- Calculer la moyenne des dépenses
  SELECT AVG(amount) INTO avg_expense
  FROM public.vendor_expenses
  WHERE vendor_id = p_vendor_id
    AND created_at > NOW() - INTERVAL '30 days';

  high_expense_threshold := avg_expense * 3;

  -- Détecter les dépenses anormalement élevées
  SELECT jsonb_agg(
    jsonb_build_object(
      'expense_id', id,
      'amount', amount,
      'description', description,
      'date', expense_date,
      'anomaly_type', 'high_amount',
      'severity', 'high'
    )
  ) INTO anomalies
  FROM public.vendor_expenses
  WHERE vendor_id = p_vendor_id
    AND amount > high_expense_threshold
    AND created_at > NOW() - INTERVAL '7 days';

  RETURN COALESCE(anomalies, '[]'::JSONB);
END;
$$;

-- =====================================================
-- TRIGGERS POUR UPDATED_AT
-- =====================================================

CREATE TRIGGER update_notifications_updated_at
  BEFORE UPDATE ON public.notifications
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_expense_categories_updated_at
  BEFORE UPDATE ON public.expense_categories
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_vendor_expenses_updated_at
  BEFORE UPDATE ON public.vendor_expenses
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_expense_budgets_updated_at
  BEFORE UPDATE ON public.expense_budgets
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

-- =====================================================
-- INDEX POUR PERFORMANCE
-- =====================================================

CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON public.notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_expense_categories_vendor_id ON public.expense_categories(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_expenses_vendor_id ON public.vendor_expenses(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_expenses_category_id ON public.vendor_expenses(category_id);
CREATE INDEX IF NOT EXISTS idx_vendor_expenses_date ON public.vendor_expenses(expense_date);
CREATE INDEX IF NOT EXISTS idx_expense_budgets_vendor_id ON public.expense_budgets(vendor_id);
CREATE INDEX IF NOT EXISTS idx_expense_analytics_vendor_id ON public.expense_analytics(vendor_id);
CREATE INDEX IF NOT EXISTS idx_expense_alerts_vendor_id ON public.expense_alerts(vendor_id);