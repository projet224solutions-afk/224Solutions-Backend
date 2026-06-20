-- ===========================================
-- MODULE GESTION FOURNISSEURS & ACHATS
-- Système complet d'achat de stock POS/ERP
-- ===========================================

-- Table des fournisseurs du vendeur (différent de suppliers global)
CREATE TABLE IF NOT EXISTS public.vendor_suppliers (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL,
  name TEXT NOT NULL,
  phone TEXT,
  email TEXT,
  address TEXT,
  notes TEXT,
  is_active BOOLEAN DEFAULT true,
  has_validated_purchases BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Table principale des achats de stock
CREATE TABLE IF NOT EXISTS public.stock_purchases (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL,
  purchase_number TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'document_generated', 'validated')),
  total_purchase_amount DECIMAL(15,2) DEFAULT 0,
  total_selling_amount DECIMAL(15,2) DEFAULT 0,
  estimated_total_profit DECIMAL(15,2) DEFAULT 0,
  notes TEXT,
  document_url TEXT,
  validated_at TIMESTAMPTZ,
  validated_by UUID,
  expense_id UUID,
  is_locked BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Table de liaison achats-fournisseurs (plusieurs fournisseurs par achat)
CREATE TABLE IF NOT EXISTS public.stock_purchase_suppliers (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  purchase_id UUID NOT NULL REFERENCES public.stock_purchases(id) ON DELETE CASCADE,
  supplier_id UUID NOT NULL REFERENCES public.vendor_suppliers(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Table des lignes d'achat (produits)
CREATE TABLE IF NOT EXISTS public.stock_purchase_items (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  purchase_id UUID NOT NULL REFERENCES public.stock_purchases(id) ON DELETE CASCADE,
  supplier_id UUID REFERENCES public.vendor_suppliers(id),
  product_id UUID REFERENCES public.products(id),
  category_id UUID REFERENCES public.categories(id),
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL DEFAULT 1,
  purchase_price DECIMAL(15,2) NOT NULL,
  selling_price DECIMAL(15,2) NOT NULL,
  unit_profit DECIMAL(15,2) GENERATED ALWAYS AS (selling_price - purchase_price) STORED,
  total_purchase DECIMAL(15,2) GENERATED ALWAYS AS (quantity * purchase_price) STORED,
  total_selling DECIMAL(15,2) GENERATED ALWAYS AS (quantity * selling_price) STORED,
  total_profit DECIMAL(15,2) GENERATED ALWAYS AS (quantity * (selling_price - purchase_price)) STORED,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes pour performance
CREATE INDEX IF NOT EXISTS idx_vendor_suppliers_vendor ON public.vendor_suppliers(vendor_id);
CREATE INDEX IF NOT EXISTS idx_stock_purchases_vendor ON public.stock_purchases(vendor_id);
CREATE INDEX IF NOT EXISTS idx_stock_purchases_status ON public.stock_purchases(status);
CREATE INDEX IF NOT EXISTS idx_stock_purchase_items_purchase ON public.stock_purchase_items(purchase_id);
CREATE INDEX IF NOT EXISTS idx_stock_purchase_suppliers_purchase ON public.stock_purchase_suppliers(purchase_id);

-- Enable RLS
ALTER TABLE public.vendor_suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_purchase_suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_purchase_items ENABLE ROW LEVEL SECURITY;

-- RLS Policies for vendor_suppliers
CREATE POLICY "Vendors can view their own suppliers"
  ON public.vendor_suppliers FOR SELECT
  USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Vendors can create their own suppliers"
  ON public.vendor_suppliers FOR INSERT
  WITH CHECK (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Vendors can update their own suppliers"
  ON public.vendor_suppliers FOR UPDATE
  USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Vendors can delete suppliers without validated purchases"
  ON public.vendor_suppliers FOR DELETE
  USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    AND has_validated_purchases = false
  );

-- RLS Policies for stock_purchases
CREATE POLICY "Vendors can view their own purchases"
  ON public.stock_purchases FOR SELECT
  USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Vendors can create their own purchases"
  ON public.stock_purchases FOR INSERT
  WITH CHECK (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Vendors can update draft purchases only"
  ON public.stock_purchases FOR UPDATE
  USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    AND is_locked = false
  );

CREATE POLICY "Vendors can delete draft purchases only"
  ON public.stock_purchases FOR DELETE
  USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    AND status = 'draft'
  );

-- RLS Policies for stock_purchase_suppliers
CREATE POLICY "Vendors can manage purchase suppliers"
  ON public.stock_purchase_suppliers FOR ALL
  USING (
    purchase_id IN (
      SELECT id FROM public.stock_purchases 
      WHERE vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    )
  );

-- RLS Policies for stock_purchase_items
CREATE POLICY "Vendors can view their purchase items"
  ON public.stock_purchase_items FOR SELECT
  USING (
    purchase_id IN (
      SELECT id FROM public.stock_purchases 
      WHERE vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
    )
  );

CREATE POLICY "Vendors can manage items in unlocked purchases"
  ON public.stock_purchase_items FOR INSERT
  WITH CHECK (
    purchase_id IN (
      SELECT id FROM public.stock_purchases 
      WHERE vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
      AND is_locked = false
    )
  );

CREATE POLICY "Vendors can update items in unlocked purchases"
  ON public.stock_purchase_items FOR UPDATE
  USING (
    purchase_id IN (
      SELECT id FROM public.stock_purchases 
      WHERE vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
      AND is_locked = false
    )
  );

CREATE POLICY "Vendors can delete items in unlocked purchases"
  ON public.stock_purchase_items FOR DELETE
  USING (
    purchase_id IN (
      SELECT id FROM public.stock_purchases 
      WHERE vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
      AND is_locked = false
    )
  );

-- Function to generate purchase number
CREATE OR REPLACE FUNCTION public.generate_purchase_number()
RETURNS TRIGGER AS $$
BEGIN
  NEW.purchase_number := 'ACH' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger for purchase number
DROP TRIGGER IF EXISTS trigger_generate_purchase_number ON public.stock_purchases;
CREATE TRIGGER trigger_generate_purchase_number
  BEFORE INSERT ON public.stock_purchases
  FOR EACH ROW
  EXECUTE FUNCTION public.generate_purchase_number();

-- Function to update purchase totals
CREATE OR REPLACE FUNCTION public.update_purchase_totals()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE public.stock_purchases
  SET 
    total_purchase_amount = COALESCE((
      SELECT SUM(total_purchase) FROM public.stock_purchase_items WHERE purchase_id = COALESCE(NEW.purchase_id, OLD.purchase_id)
    ), 0),
    total_selling_amount = COALESCE((
      SELECT SUM(total_selling) FROM public.stock_purchase_items WHERE purchase_id = COALESCE(NEW.purchase_id, OLD.purchase_id)
    ), 0),
    estimated_total_profit = COALESCE((
      SELECT SUM(total_profit) FROM public.stock_purchase_items WHERE purchase_id = COALESCE(NEW.purchase_id, OLD.purchase_id)
    ), 0),
    updated_at = NOW()
  WHERE id = COALESCE(NEW.purchase_id, OLD.purchase_id);
  
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger to auto-update totals
DROP TRIGGER IF EXISTS trigger_update_purchase_totals ON public.stock_purchase_items;
CREATE TRIGGER trigger_update_purchase_totals
  AFTER INSERT OR UPDATE OR DELETE ON public.stock_purchase_items
  FOR EACH ROW
  EXECUTE FUNCTION public.update_purchase_totals();

-- Function to mark supplier as having validated purchases
CREATE OR REPLACE FUNCTION public.mark_supplier_validated()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'validated' AND OLD.status != 'validated' THEN
    UPDATE public.vendor_suppliers
    SET has_validated_purchases = true
    WHERE id IN (
      SELECT supplier_id FROM public.stock_purchase_suppliers WHERE purchase_id = NEW.id
      UNION
      SELECT supplier_id FROM public.stock_purchase_items WHERE purchase_id = NEW.id AND supplier_id IS NOT NULL
    );
    
    NEW.is_locked := true;
    NEW.validated_at := NOW();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger to mark supplier as validated
DROP TRIGGER IF EXISTS trigger_mark_supplier_validated ON public.stock_purchases;
CREATE TRIGGER trigger_mark_supplier_validated
  BEFORE UPDATE ON public.stock_purchases
  FOR EACH ROW
  EXECUTE FUNCTION public.mark_supplier_validated();