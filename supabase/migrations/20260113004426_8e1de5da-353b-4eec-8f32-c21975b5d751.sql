-- =============================================
-- MODULE DROPSHIPPING COMPLET
-- Extension indépendante pour e-commerce dropshipping
-- =============================================

-- 1. TABLE DROPSHIP_SUPPLIERS (Fournisseurs Dropshipping)
CREATE TABLE IF NOT EXISTS public.dropship_suppliers (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  country TEXT NOT NULL DEFAULT 'CN',
  currency TEXT NOT NULL DEFAULT 'USD',
  supplier_type TEXT NOT NULL DEFAULT 'international' CHECK (supplier_type IN ('local', 'international')),
  reliability_score DECIMAL(3,2) DEFAULT 4.00 CHECK (reliability_score >= 0 AND reliability_score <= 5),
  total_deliveries INTEGER DEFAULT 0,
  successful_deliveries INTEGER DEFAULT 0,
  average_delivery_days INTEGER DEFAULT 14,
  api_endpoint TEXT,
  api_key_encrypted TEXT,
  webhook_url TEXT,
  contact_email TEXT,
  contact_phone TEXT,
  website_url TEXT,
  logo_url TEXT,
  description TEXT,
  commission_rate DECIMAL(5,2) DEFAULT 0,
  min_order_value DECIMAL(12,2) DEFAULT 0,
  supported_countries TEXT[] DEFAULT ARRAY['GN', 'SN', 'CI', 'ML'],
  payment_methods TEXT[] DEFAULT ARRAY['bank_transfer', 'paypal'],
  is_verified BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 2. TABLE DROPSHIP_PRODUCTS (Produits Dropshipping)
CREATE TABLE IF NOT EXISTS public.dropship_products (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  supplier_id UUID NOT NULL REFERENCES public.dropship_suppliers(id) ON DELETE RESTRICT,
  original_product_id UUID REFERENCES public.products(id) ON DELETE SET NULL,
  
  -- Infos fournisseur
  supplier_product_id TEXT,
  supplier_product_url TEXT,
  supplier_price DECIMAL(12,2) NOT NULL,
  supplier_currency TEXT DEFAULT 'USD',
  
  -- Infos vendeur
  product_name TEXT NOT NULL,
  product_description TEXT,
  selling_price DECIMAL(12,2) NOT NULL,
  selling_currency TEXT DEFAULT 'GNF',
  margin_percent DECIMAL(5,2),
  
  -- Stock & Disponibilité
  supplier_stock INTEGER DEFAULT 0,
  is_available BOOLEAN DEFAULT true,
  availability_status TEXT DEFAULT 'available' CHECK (availability_status IN ('available', 'low_stock', 'out_of_stock', 'temporarily_unavailable', 'discontinued')),
  
  -- Livraison
  estimated_delivery_min INTEGER DEFAULT 7,
  estimated_delivery_max INTEGER DEFAULT 21,
  shipping_cost DECIMAL(12,2) DEFAULT 0,
  
  -- Sync
  auto_sync_enabled BOOLEAN DEFAULT true,
  last_sync_at TIMESTAMPTZ,
  sync_errors TEXT[],
  
  -- Catégorisation
  category TEXT,
  tags TEXT[],
  images TEXT[],
  variants JSONB DEFAULT '[]',
  
  -- Stats
  total_orders INTEGER DEFAULT 0,
  total_sold INTEGER DEFAULT 0,
  rating DECIMAL(3,2) DEFAULT 0,
  
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 3. TABLE DROPSHIP_ORDERS (Commandes Dropshipping - Sous-commandes fournisseur)
CREATE TABLE IF NOT EXISTS public.dropship_orders (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  
  -- Références
  customer_order_id UUID NOT NULL,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id),
  supplier_id UUID NOT NULL REFERENCES public.dropship_suppliers(id),
  dropship_product_id UUID REFERENCES public.dropship_products(id),
  
  -- Infos commande
  order_reference TEXT NOT NULL UNIQUE DEFAULT ('DS-' || UPPER(SUBSTRING(gen_random_uuid()::text, 1, 8))),
  supplier_order_reference TEXT,
  
  -- Produits
  items JSONB NOT NULL DEFAULT '[]',
  quantity INTEGER NOT NULL DEFAULT 1,
  
  -- Prix
  supplier_total DECIMAL(12,2) NOT NULL,
  supplier_currency TEXT DEFAULT 'USD',
  customer_total DECIMAL(12,2) NOT NULL,
  customer_currency TEXT DEFAULT 'GNF',
  profit_amount DECIMAL(12,2),
  
  -- Statuts
  status TEXT DEFAULT 'pending' CHECK (status IN (
    'pending',
    'awaiting_supplier',
    'ordered_from_supplier',
    'supplier_confirmed',
    'supplier_processing',
    'shipped_by_supplier',
    'in_transit',
    'delivered_to_customer',
    'completed',
    'cancelled',
    'refunded',
    'disputed'
  )),
  
  -- Livraison
  shipping_address JSONB,
  tracking_number TEXT,
  tracking_url TEXT,
  shipped_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  estimated_delivery_date DATE,
  
  -- Paiement
  supplier_payment_status TEXT DEFAULT 'pending' CHECK (supplier_payment_status IN ('pending', 'processing', 'paid', 'failed', 'refunded')),
  supplier_paid_at TIMESTAMPTZ,
  vendor_payment_status TEXT DEFAULT 'held' CHECK (vendor_payment_status IN ('held', 'released', 'paid', 'refunded')),
  vendor_paid_at TIMESTAMPTZ,
  
  -- Notes
  customer_notes TEXT,
  vendor_notes TEXT,
  supplier_notes TEXT,
  
  -- Incidents
  has_issue BOOLEAN DEFAULT false,
  issue_type TEXT,
  issue_description TEXT,
  issue_resolved_at TIMESTAMPTZ,
  
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 4. TABLE DROPSHIP_SYNC_LOGS (Logs de synchronisation)
CREATE TABLE IF NOT EXISTS public.dropship_sync_logs (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  supplier_id UUID REFERENCES public.dropship_suppliers(id),
  product_id UUID REFERENCES public.dropship_products(id),
  
  sync_type TEXT NOT NULL CHECK (sync_type IN ('manual', 'automatic', 'webhook', 'cron')),
  sync_scope TEXT DEFAULT 'product' CHECK (sync_scope IN ('product', 'stock', 'price', 'all', 'supplier')),
  
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'success', 'partial', 'failed')),
  
  changes_detected JSONB DEFAULT '{}',
  products_updated INTEGER DEFAULT 0,
  prices_updated INTEGER DEFAULT 0,
  stocks_updated INTEGER DEFAULT 0,
  errors TEXT[],
  
  started_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ,
  duration_ms INTEGER
);

-- 5. TABLE DROPSHIP_INCIDENTS (Historique incidents fournisseurs)
CREATE TABLE IF NOT EXISTS public.dropship_incidents (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  supplier_id UUID NOT NULL REFERENCES public.dropship_suppliers(id),
  order_id UUID REFERENCES public.dropship_orders(id),
  vendor_id UUID REFERENCES public.vendors(id),
  
  incident_type TEXT NOT NULL CHECK (incident_type IN (
    'late_delivery',
    'wrong_product',
    'damaged_product',
    'missing_product',
    'quality_issue',
    'price_discrepancy',
    'communication_failure',
    'refund_issue',
    'other'
  )),
  
  severity TEXT DEFAULT 'medium' CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  description TEXT NOT NULL,
  resolution TEXT,
  financial_impact DECIMAL(12,2) DEFAULT 0,
  
  status TEXT DEFAULT 'open' CHECK (status IN ('open', 'investigating', 'resolved', 'escalated', 'closed')),
  resolved_at TIMESTAMPTZ,
  resolved_by UUID,
  
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 6. TABLE DROPSHIP_SETTINGS (Configuration par vendeur)
CREATE TABLE IF NOT EXISTS public.dropship_settings (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL UNIQUE REFERENCES public.vendors(id) ON DELETE CASCADE,
  
  -- Activation
  is_enabled BOOLEAN DEFAULT true,
  
  -- Marges par défaut
  default_margin_percent DECIMAL(5,2) DEFAULT 20,
  min_margin_percent DECIMAL(5,2) DEFAULT 10,
  
  -- Synchronisation
  auto_sync_enabled BOOLEAN DEFAULT true,
  sync_frequency_hours INTEGER DEFAULT 6,
  last_full_sync_at TIMESTAMPTZ,
  
  -- Notifications
  notify_low_stock BOOLEAN DEFAULT true,
  notify_price_changes BOOLEAN DEFAULT true,
  notify_supplier_issues BOOLEAN DEFAULT true,
  low_stock_threshold INTEGER DEFAULT 5,
  
  -- Paiements
  hold_payment_days INTEGER DEFAULT 7,
  auto_release_on_delivery BOOLEAN DEFAULT true,
  
  -- Affichage
  show_supplier_name BOOLEAN DEFAULT false,
  show_estimated_delivery BOOLEAN DEFAULT true,
  
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 7. TABLE DROPSHIP_REPORTS (Rapports agrégés)
CREATE TABLE IF NOT EXISTS public.dropship_reports (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id),
  report_period TEXT NOT NULL,
  report_date DATE NOT NULL,
  
  -- Métriques
  total_orders INTEGER DEFAULT 0,
  completed_orders INTEGER DEFAULT 0,
  cancelled_orders INTEGER DEFAULT 0,
  disputed_orders INTEGER DEFAULT 0,
  
  total_revenue DECIMAL(14,2) DEFAULT 0,
  total_costs DECIMAL(14,2) DEFAULT 0,
  total_profit DECIMAL(14,2) DEFAULT 0,
  average_margin_percent DECIMAL(5,2) DEFAULT 0,
  
  average_delivery_days DECIMAL(5,2) DEFAULT 0,
  on_time_delivery_rate DECIMAL(5,2) DEFAULT 0,
  
  top_products JSONB DEFAULT '[]',
  top_suppliers JSONB DEFAULT '[]',
  
  created_at TIMESTAMPTZ DEFAULT now(),
  
  UNIQUE(vendor_id, report_period, report_date)
);

-- =============================================
-- INDEXES
-- =============================================

CREATE INDEX IF NOT EXISTS idx_dropship_products_vendor ON public.dropship_products(vendor_id);
CREATE INDEX IF NOT EXISTS idx_dropship_products_supplier ON public.dropship_products(supplier_id);
CREATE INDEX IF NOT EXISTS idx_dropship_products_active ON public.dropship_products(is_active, availability_status);
CREATE INDEX IF NOT EXISTS idx_dropship_orders_vendor ON public.dropship_orders(vendor_id);
CREATE INDEX IF NOT EXISTS idx_dropship_orders_supplier ON public.dropship_orders(supplier_id);
CREATE INDEX IF NOT EXISTS idx_dropship_orders_status ON public.dropship_orders(status);
CREATE INDEX IF NOT EXISTS idx_dropship_orders_customer ON public.dropship_orders(customer_order_id);
CREATE INDEX IF NOT EXISTS idx_dropship_incidents_supplier ON public.dropship_incidents(supplier_id);
CREATE INDEX IF NOT EXISTS idx_dropship_sync_logs_supplier ON public.dropship_sync_logs(supplier_id);

-- =============================================
-- ROW LEVEL SECURITY
-- =============================================

ALTER TABLE public.dropship_suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dropship_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dropship_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dropship_sync_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dropship_incidents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dropship_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dropship_reports ENABLE ROW LEVEL SECURITY;

-- Suppliers: Lecture publique, admin pour modifications
CREATE POLICY "Public read dropship suppliers" ON public.dropship_suppliers FOR SELECT USING (is_active = true);
CREATE POLICY "Admin manage dropship suppliers" ON public.dropship_suppliers FOR ALL USING (
  EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
);

-- Products: Vendeur propriétaire
CREATE POLICY "Vendor manage own dropship products" ON public.dropship_products FOR ALL USING (
  vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
);
CREATE POLICY "Public read active dropship products" ON public.dropship_products FOR SELECT USING (is_active = true AND is_available = true);

-- Orders: Vendeur propriétaire
CREATE POLICY "Vendor manage own dropship orders" ON public.dropship_orders FOR ALL USING (
  vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
);

-- Sync Logs: Lecture pour vendeurs avec produits
CREATE POLICY "Vendor read own dropship sync logs" ON public.dropship_sync_logs FOR SELECT USING (
  product_id IN (SELECT id FROM public.dropship_products WHERE vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()))
);

-- Incidents: Vendeur concerné
CREATE POLICY "Vendor read own dropship incidents" ON public.dropship_incidents FOR SELECT USING (
  vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
);

-- Settings: Vendeur propriétaire
CREATE POLICY "Vendor manage own dropship settings" ON public.dropship_settings FOR ALL USING (
  vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
);

-- Reports: Vendeur propriétaire
CREATE POLICY "Vendor read own dropship reports" ON public.dropship_reports FOR SELECT USING (
  vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid())
);

-- =============================================
-- TRIGGERS
-- =============================================

CREATE OR REPLACE FUNCTION public.dropship_update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

DROP TRIGGER IF EXISTS dropship_suppliers_updated ON public.dropship_suppliers;
DROP TRIGGER IF EXISTS dropship_products_updated ON public.dropship_products;
DROP TRIGGER IF EXISTS dropship_orders_updated ON public.dropship_orders;
DROP TRIGGER IF EXISTS dropship_settings_updated ON public.dropship_settings;

CREATE TRIGGER dropship_suppliers_updated BEFORE UPDATE ON public.dropship_suppliers FOR EACH ROW EXECUTE FUNCTION public.dropship_update_timestamp();
CREATE TRIGGER dropship_products_updated BEFORE UPDATE ON public.dropship_products FOR EACH ROW EXECUTE FUNCTION public.dropship_update_timestamp();
CREATE TRIGGER dropship_orders_updated BEFORE UPDATE ON public.dropship_orders FOR EACH ROW EXECUTE FUNCTION public.dropship_update_timestamp();
CREATE TRIGGER dropship_settings_updated BEFORE UPDATE ON public.dropship_settings FOR EACH ROW EXECUTE FUNCTION public.dropship_update_timestamp();

-- =============================================
-- DONNÉES INITIALES (Fournisseurs de démonstration)
-- =============================================

INSERT INTO public.dropship_suppliers (name, country, currency, supplier_type, reliability_score, website_url, description, supported_countries, is_verified)
VALUES 
  ('AliExpress Global', 'CN', 'USD', 'international', 4.20, 'https://aliexpress.com', 'Plus grand marketplace B2C chinois avec millions de produits', ARRAY['GN', 'SN', 'CI', 'ML', 'BF', 'NE', 'TG', 'BJ'], true),
  ('CJ Dropshipping', 'CN', 'USD', 'international', 4.50, 'https://cjdropshipping.com', 'Plateforme dropshipping avec fulfillment et branding personnalisé', ARRAY['GN', 'SN', 'CI', 'ML', 'BF', 'NE', 'TG', 'BJ'], true),
  ('Spocket EU', 'EU', 'EUR', 'international', 4.30, 'https://spocket.co', 'Fournisseurs européens et américains avec livraison rapide', ARRAY['GN', 'SN', 'CI', 'ML'], true),
  ('Afrik Dropship', 'SN', 'XOF', 'local', 4.00, NULL, 'Fournisseur local spécialisé Afrique de Ouest', ARRAY['GN', 'SN', 'CI', 'ML', 'BF', 'NE', 'TG', 'BJ', 'GW'], true),
  ('Dubai Wholesale', 'AE', 'USD', 'international', 4.10, NULL, 'Grossiste Dubai avec produits électroniques et mode', ARRAY['GN', 'SN', 'CI', 'ML'], true)
ON CONFLICT DO NOTHING;