-- =====================================================
-- MIGRATION: Amélioration du système de gestion d'achats et ventes
-- =====================================================

-- 1. Ajouter les colonnes de remise par article dans order_items
ALTER TABLE public.order_items 
ADD COLUMN IF NOT EXISTS cost_price numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS discount_type varchar(20) DEFAULT NULL,
ADD COLUMN IF NOT EXISTS discount_value numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS discount_amount numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS original_unit_price numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS final_unit_price numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS profit_before_discount numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS profit_after_discount numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS loss_amount numeric DEFAULT 0;

-- 2. Ajouter colonne is_locked à vendor_expenses pour verrouiller après validation
ALTER TABLE public.vendor_expenses 
ADD COLUMN IF NOT EXISTS is_locked boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS purchase_reference varchar(100) DEFAULT NULL;

-- 3. Créer index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_order_items_cost_price ON public.order_items(cost_price);
CREATE INDEX IF NOT EXISTS idx_order_items_discount ON public.order_items(discount_type);
CREATE INDEX IF NOT EXISTS idx_vendor_expenses_locked ON public.vendor_expenses(is_locked);
CREATE INDEX IF NOT EXISTS idx_vendor_expenses_purchase_ref ON public.vendor_expenses(purchase_reference);

-- 4. Créer une politique RLS pour empêcher la modification des dépenses verrouillées
DROP POLICY IF EXISTS "Prevent update on locked expenses" ON public.vendor_expenses;
CREATE POLICY "Prevent update on locked expenses" ON public.vendor_expenses
FOR UPDATE
USING (
  is_locked = false OR 
  auth.uid() IN (SELECT user_id FROM vendors WHERE id = vendor_id)
);

DROP POLICY IF EXISTS "Prevent delete on locked expenses" ON public.vendor_expenses;
CREATE POLICY "Prevent delete on locked expenses" ON public.vendor_expenses
FOR DELETE
USING (is_locked = false);

-- 5. Fonction pour calculer les profits/pertes sur les order_items
CREATE OR REPLACE FUNCTION public.calculate_order_item_profits()
RETURNS TRIGGER AS $$
BEGIN
  -- Calculer profit avant remise
  NEW.profit_before_discount := (NEW.original_unit_price - COALESCE(NEW.cost_price, 0)) * NEW.quantity;
  
  -- Calculer profit après remise
  NEW.profit_after_discount := (NEW.final_unit_price - COALESCE(NEW.cost_price, 0)) * NEW.quantity;
  
  -- Calculer la perte due à la remise (si prix final < cost_price)
  IF NEW.final_unit_price < COALESCE(NEW.cost_price, 0) THEN
    NEW.loss_amount := (COALESCE(NEW.cost_price, 0) - NEW.final_unit_price) * NEW.quantity;
  ELSE
    NEW.loss_amount := 0;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

-- 6. Trigger pour calculer automatiquement les profits
DROP TRIGGER IF EXISTS calculate_order_item_profits_trigger ON public.order_items;
CREATE TRIGGER calculate_order_item_profits_trigger
BEFORE INSERT OR UPDATE ON public.order_items
FOR EACH ROW
EXECUTE FUNCTION public.calculate_order_item_profits();

-- 7. Vue pour les statistiques de profits et pertes du vendeur
CREATE OR REPLACE VIEW public.vendor_profit_stats AS
SELECT 
  o.vendor_id,
  DATE(o.created_at) as sale_date,
  SUM(oi.total_price) as total_sales,
  SUM(oi.profit_before_discount) as total_profit_before_discount,
  SUM(oi.profit_after_discount) as total_profit_after_discount,
  SUM(oi.discount_amount) as total_discounts,
  SUM(oi.loss_amount) as total_losses,
  COUNT(DISTINCT o.id) as order_count,
  SUM(oi.quantity) as items_sold
FROM public.orders o
JOIN public.order_items oi ON oi.order_id = o.id
WHERE o.payment_status = 'paid'
GROUP BY o.vendor_id, DATE(o.created_at);

-- 8. Fonction pour verrouiller une dépense liée à un achat
CREATE OR REPLACE FUNCTION public.lock_expense_for_purchase(expense_uuid uuid)
RETURNS void AS $$
BEGIN
  UPDATE public.vendor_expenses
  SET is_locked = true
  WHERE id = expense_uuid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;