-- ============================================
-- EXTENSION MODULE DROPSHIPPING CHINE
-- Aucune modification des tables existantes
-- Ajout de nouvelles colonnes et tables uniquement
-- ============================================

-- 1. EXTENSION TABLE dropship_suppliers - Colonnes Chine
ALTER TABLE dropship_suppliers 
ADD COLUMN IF NOT EXISTS supplier_region TEXT DEFAULT 'OTHER',
ADD COLUMN IF NOT EXISTS platform_type TEXT DEFAULT 'PRIVATE',
ADD COLUMN IF NOT EXISTS platform_shop_url TEXT,
ADD COLUMN IF NOT EXISTS moq INTEGER DEFAULT 1,
ADD COLUMN IF NOT EXISTS production_time_days INTEGER,
ADD COLUMN IF NOT EXISTS domestic_shipping_days INTEGER,
ADD COLUMN IF NOT EXISTS international_shipping_days INTEGER,
ADD COLUMN IF NOT EXISTS incoterm TEXT DEFAULT 'EXW',
ADD COLUMN IF NOT EXISTS chinese_language_support BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS quality_score DECIMAL(3,2) DEFAULT 5.00,
ADD COLUMN IF NOT EXISTS delivery_success_rate DECIMAL(5,2) DEFAULT 100.00,
ADD COLUMN IF NOT EXISTS on_time_rate DECIMAL(5,2) DEFAULT 100.00,
ADD COLUMN IF NOT EXISTS dispute_rate DECIMAL(5,2) DEFAULT 0.00,
ADD COLUMN IF NOT EXISTS total_orders INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS successful_orders INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS is_verified BOOLEAN DEFAULT false,
ADD COLUMN IF NOT EXISTS verified_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS verified_by UUID;

-- 2. EXTENSION TABLE dropship_products - Colonnes Chine
ALTER TABLE dropship_products
ADD COLUMN IF NOT EXISTS platform_product_id TEXT,
ADD COLUMN IF NOT EXISTS platform_type TEXT,
ADD COLUMN IF NOT EXISTS original_images JSONB DEFAULT '[]'::jsonb,
ADD COLUMN IF NOT EXISTS variants JSONB DEFAULT '[]'::jsonb,
ADD COLUMN IF NOT EXISTS moq INTEGER DEFAULT 1,
ADD COLUMN IF NOT EXISTS production_time_days INTEGER,
ADD COLUMN IF NOT EXISTS supplier_region TEXT,
ADD COLUMN IF NOT EXISTS cost_breakdown JSONB DEFAULT '{}'::jsonb,
ADD COLUMN IF NOT EXISTS import_source_url TEXT,
ADD COLUMN IF NOT EXISTS imported_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS last_price_alert TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS price_change_percent DECIMAL(5,2);

-- 3. EXTENSION TABLE dropship_orders - Colonnes logistique Chine
ALTER TABLE dropship_orders
ADD COLUMN IF NOT EXISTS transport_method TEXT DEFAULT 'express',
ADD COLUMN IF NOT EXISTS estimated_customs_delay INTEGER,
ADD COLUMN IF NOT EXISTS last_mile_carrier TEXT,
ADD COLUMN IF NOT EXISTS tracking_segments JSONB DEFAULT '[]'::jsonb,
ADD COLUMN IF NOT EXISTS china_internal_tracking TEXT,
ADD COLUMN IF NOT EXISTS international_tracking TEXT,
ADD COLUMN IF NOT EXISTS customs_status TEXT,
ADD COLUMN IF NOT EXISTS customs_cleared_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS supplier_order_ref TEXT,
ADD COLUMN IF NOT EXISTS supplier_order_data JSONB DEFAULT '{}'::jsonb,
ADD COLUMN IF NOT EXISTS cost_breakdown JSONB DEFAULT '{}'::jsonb,
ADD COLUMN IF NOT EXISTS actual_delivery_days INTEGER,
ADD COLUMN IF NOT EXISTS quality_check_status TEXT DEFAULT 'pending',
ADD COLUMN IF NOT EXISTS quality_check_notes TEXT;

-- 4. TABLE: Logs d'import produits Chine
CREATE TABLE IF NOT EXISTS dropship_china_imports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL,
  source_url TEXT NOT NULL,
  platform_type TEXT NOT NULL,
  platform_product_id TEXT,
  import_status TEXT DEFAULT 'pending',
  extracted_data JSONB DEFAULT '{}'::jsonb,
  error_message TEXT,
  product_id UUID REFERENCES dropship_products(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ
);

-- 5. TABLE: Alertes prix Chine
CREATE TABLE IF NOT EXISTS dropship_price_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES dropship_products(id) ON DELETE CASCADE,
  vendor_id UUID NOT NULL,
  old_price DECIMAL(15,2) NOT NULL,
  new_price DECIMAL(15,2) NOT NULL,
  old_currency TEXT NOT NULL,
  change_percent DECIMAL(5,2) NOT NULL,
  alert_type TEXT NOT NULL, -- 'increase', 'decrease', 'unavailable'
  is_acknowledged BOOLEAN DEFAULT false,
  acknowledged_at TIMESTAMPTZ,
  acknowledged_by UUID,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 6. TABLE: Suivi logistique multi-segments Chine
CREATE TABLE IF NOT EXISTS dropship_china_tracking (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES dropship_orders(id) ON DELETE CASCADE,
  segment_type TEXT NOT NULL, -- 'china_domestic', 'international', 'customs', 'last_mile'
  carrier_name TEXT,
  tracking_number TEXT,
  status TEXT DEFAULT 'pending',
  status_details TEXT,
  location TEXT,
  estimated_arrival TIMESTAMPTZ,
  actual_arrival TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 7. TABLE: Calcul coûts détaillés Chine
CREATE TABLE IF NOT EXISTS dropship_china_costs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES dropship_products(id) ON DELETE CASCADE,
  vendor_id UUID NOT NULL,
  supplier_price DECIMAL(15,2) NOT NULL,
  supplier_currency TEXT DEFAULT 'CNY',
  china_domestic_shipping DECIMAL(15,2) DEFAULT 0,
  international_shipping DECIMAL(15,2) DEFAULT 0,
  estimated_customs DECIMAL(15,2) DEFAULT 0,
  platform_fees DECIMAL(15,2) DEFAULT 0,
  exchange_rate DECIMAL(10,4),
  exchange_rate_date DATE,
  total_cost_usd DECIMAL(15,2),
  vendor_margin DECIMAL(15,2),
  vendor_margin_percent DECIMAL(5,2),
  final_price_local DECIMAL(15,2),
  local_currency TEXT,
  is_current BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 8. TABLE: Scoring fournisseurs Chine
CREATE TABLE IF NOT EXISTS dropship_supplier_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_id UUID NOT NULL REFERENCES dropship_suppliers(id) ON DELETE CASCADE,
  order_id UUID REFERENCES dropship_orders(id) ON DELETE SET NULL,
  vendor_id UUID NOT NULL,
  rating INTEGER CHECK (rating >= 1 AND rating <= 5),
  delivery_rating INTEGER CHECK (delivery_rating >= 1 AND delivery_rating <= 5),
  quality_rating INTEGER CHECK (quality_rating >= 1 AND quality_rating <= 5),
  communication_rating INTEGER CHECK (communication_rating >= 1 AND communication_rating <= 5),
  review_text TEXT,
  is_dispute BOOLEAN DEFAULT false,
  dispute_reason TEXT,
  dispute_resolved BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 9. TABLE: Logs Chine (séparés)
CREATE TABLE IF NOT EXISTS dropship_china_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  log_type TEXT NOT NULL, -- 'import', 'sync', 'order', 'tracking', 'error', 'alert'
  severity TEXT DEFAULT 'info', -- 'info', 'warning', 'error', 'critical'
  entity_type TEXT, -- 'product', 'order', 'supplier', 'tracking'
  entity_id UUID,
  vendor_id UUID,
  message TEXT NOT NULL,
  details JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 10. TABLE: Configuration Chine par vendeur
CREATE TABLE IF NOT EXISTS dropship_china_settings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL UNIQUE,
  default_transport_method TEXT DEFAULT 'express',
  auto_block_unavailable BOOLEAN DEFAULT true,
  unavailable_threshold_days INTEGER DEFAULT 7,
  price_increase_alert_percent DECIMAL(5,2) DEFAULT 10.00,
  auto_update_prices BOOLEAN DEFAULT false,
  show_origin_to_customer BOOLEAN DEFAULT true,
  default_customs_estimate_percent DECIMAL(5,2) DEFAULT 15.00,
  preferred_incoterm TEXT DEFAULT 'FOB',
  min_supplier_score DECIMAL(3,2) DEFAULT 3.50,
  auto_disable_low_score BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 11. TABLE: Rapports Chine
CREATE TABLE IF NOT EXISTS dropship_china_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID,
  report_type TEXT NOT NULL, -- 'margin', 'delivery', 'customs', 'supplier_performance'
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  summary JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- INDEXES
CREATE INDEX IF NOT EXISTS idx_dropship_suppliers_region ON dropship_suppliers(supplier_region);
CREATE INDEX IF NOT EXISTS idx_dropship_suppliers_platform ON dropship_suppliers(platform_type);
CREATE INDEX IF NOT EXISTS idx_dropship_suppliers_score ON dropship_suppliers(quality_score);
CREATE INDEX IF NOT EXISTS idx_dropship_products_platform ON dropship_products(platform_type);
CREATE INDEX IF NOT EXISTS idx_dropship_products_region ON dropship_products(supplier_region);
CREATE INDEX IF NOT EXISTS idx_china_imports_vendor ON dropship_china_imports(vendor_id);
CREATE INDEX IF NOT EXISTS idx_china_imports_status ON dropship_china_imports(import_status);
CREATE INDEX IF NOT EXISTS idx_price_alerts_product ON dropship_price_alerts(product_id);
CREATE INDEX IF NOT EXISTS idx_price_alerts_vendor ON dropship_price_alerts(vendor_id);
CREATE INDEX IF NOT EXISTS idx_china_tracking_order ON dropship_china_tracking(order_id);
CREATE INDEX IF NOT EXISTS idx_china_costs_product ON dropship_china_costs(product_id);
CREATE INDEX IF NOT EXISTS idx_supplier_reviews_supplier ON dropship_supplier_reviews(supplier_id);
CREATE INDEX IF NOT EXISTS idx_china_logs_type ON dropship_china_logs(log_type);
CREATE INDEX IF NOT EXISTS idx_china_logs_vendor ON dropship_china_logs(vendor_id);
CREATE INDEX IF NOT EXISTS idx_china_reports_vendor ON dropship_china_reports(vendor_id);

-- RLS POLICIES
ALTER TABLE dropship_china_imports ENABLE ROW LEVEL SECURITY;
ALTER TABLE dropship_price_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE dropship_china_tracking ENABLE ROW LEVEL SECURITY;
ALTER TABLE dropship_china_costs ENABLE ROW LEVEL SECURITY;
ALTER TABLE dropship_supplier_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE dropship_china_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE dropship_china_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE dropship_china_reports ENABLE ROW LEVEL SECURITY;

-- Policies pour dropship_china_imports
CREATE POLICY "Vendors can manage their imports" ON dropship_china_imports
  FOR ALL USING (vendor_id = auth.uid());

CREATE POLICY "Admin can view all imports" ON dropship_china_imports
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- Policies pour dropship_price_alerts
CREATE POLICY "Vendors can view their alerts" ON dropship_price_alerts
  FOR SELECT USING (vendor_id = auth.uid());

CREATE POLICY "System can manage alerts" ON dropship_price_alerts
  FOR ALL USING (true);

-- Policies pour dropship_china_tracking
CREATE POLICY "Vendors can view order tracking" ON dropship_china_tracking
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM dropship_orders o 
      WHERE o.id = dropship_china_tracking.order_id 
      AND o.vendor_id = auth.uid()
    )
  );

CREATE POLICY "Admin can manage tracking" ON dropship_china_tracking
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- Policies pour dropship_china_costs
CREATE POLICY "Vendors can manage their costs" ON dropship_china_costs
  FOR ALL USING (vendor_id = auth.uid());

-- Policies pour dropship_supplier_reviews
CREATE POLICY "Vendors can manage their reviews" ON dropship_supplier_reviews
  FOR ALL USING (vendor_id = auth.uid());

CREATE POLICY "Anyone can view reviews" ON dropship_supplier_reviews
  FOR SELECT USING (true);

-- Policies pour dropship_china_logs
CREATE POLICY "Vendors can view their logs" ON dropship_china_logs
  FOR SELECT USING (vendor_id = auth.uid() OR vendor_id IS NULL);

CREATE POLICY "System can insert logs" ON dropship_china_logs
  FOR INSERT WITH CHECK (true);

-- Policies pour dropship_china_settings
CREATE POLICY "Vendors can manage their settings" ON dropship_china_settings
  FOR ALL USING (vendor_id = auth.uid());

-- Policies pour dropship_china_reports
CREATE POLICY "Vendors can view their reports" ON dropship_china_reports
  FOR SELECT USING (vendor_id = auth.uid() OR vendor_id IS NULL);

CREATE POLICY "Admin can manage reports" ON dropship_china_reports
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- TRIGGER pour updated_at
CREATE OR REPLACE FUNCTION update_china_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_china_tracking_updated_at
  BEFORE UPDATE ON dropship_china_tracking
  FOR EACH ROW EXECUTE FUNCTION update_china_updated_at();

CREATE TRIGGER update_china_costs_updated_at
  BEFORE UPDATE ON dropship_china_costs
  FOR EACH ROW EXECUTE FUNCTION update_china_updated_at();

CREATE TRIGGER update_china_settings_updated_at
  BEFORE UPDATE ON dropship_china_settings
  FOR EACH ROW EXECUTE FUNCTION update_china_updated_at();

-- INSERT fournisseurs chinois de démonstration
INSERT INTO dropship_suppliers (
  name, country, currency, supplier_type, website_url, 
  reliability_score, is_active,
  supplier_region, platform_type, moq, production_time_days,
  domestic_shipping_days, international_shipping_days, incoterm,
  chinese_language_support, is_verified
) VALUES 
  ('Alibaba Global', 'China', 'CNY', 'international', 'https://www.alibaba.com',
   4.2, true, 'CHINA', 'ALIBABA', 10, 3, 2, 15, 'FOB', true, true),
  ('1688 Direct', 'China', 'CNY', 'international', 'https://www.1688.com',
   3.8, true, 'CHINA', '1688', 5, 2, 1, 20, 'EXW', true, true),
  ('AliExpress Express', 'China', 'USD', 'international', 'https://www.aliexpress.com',
   4.5, true, 'CHINA', 'ALIEXPRESS', 1, 1, 1, 25, 'CIF', false, true),
  ('Shenzhen Electronics Hub', 'China', 'CNY', 'international', 'https://example-shenzhen.com',
   4.0, true, 'CHINA', 'PRIVATE', 20, 5, 3, 18, 'FOB', true, false),
  ('Guangzhou Fashion Factory', 'China', 'CNY', 'international', 'https://example-guangzhou.com',
   3.5, true, 'CHINA', 'PRIVATE', 50, 7, 2, 22, 'EXW', true, false)
ON CONFLICT DO NOTHING;