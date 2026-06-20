-- =============================================
-- CHINA DROPSHIPPING MODULE - Database Schema
-- Extension modulaire pour fournisseurs chinois
-- Date: 2026-01-12
-- Version: 1.0.0
-- 
-- ⚠️ EXTENSION ONLY - Ne modifie pas les tables existantes
-- =============================================

-- ============================================================================
-- PARTIE 1: EXTENSION FOURNISSEURS CHINOIS
-- ============================================================================

-- Table des fournisseurs chinois (extension des dropship_suppliers)
CREATE TABLE IF NOT EXISTS public.china_suppliers (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  supplier_id UUID REFERENCES public.dropship_suppliers(id) ON DELETE SET NULL,
  
  -- Région et plateforme
  supplier_region TEXT NOT NULL DEFAULT 'CHINA' CHECK (supplier_region IN ('CHINA', 'LOCAL', 'INTERNATIONAL')),
  platform_type TEXT NOT NULL DEFAULT 'ALIBABA' CHECK (platform_type IN ('ALIBABA', 'ALIEXPRESS', '1688', 'PRIVATE')),
  platform_shop_id TEXT,
  platform_shop_url TEXT,
  platform_rating DECIMAL(3,2) CHECK (platform_rating >= 0 AND platform_rating <= 5),
  platform_years_active INTEGER DEFAULT 0,
  platform_verified BOOLEAN DEFAULT false,
  
  -- Capacités commande
  moq INTEGER NOT NULL DEFAULT 1, -- Minimum Order Quantity
  production_time_days INTEGER NOT NULL DEFAULT 3,
  domestic_shipping_days INTEGER NOT NULL DEFAULT 2, -- Chine interne
  international_shipping_days INTEGER NOT NULL DEFAULT 15,
  
  -- Termes commerciaux
  incoterm TEXT NOT NULL DEFAULT 'FOB' CHECK (incoterm IN ('EXW', 'FOB', 'CIF', 'DDP', 'DAP')),
  accepts_small_orders BOOLEAN DEFAULT true,
  accepts_customization BOOLEAN DEFAULT false,
  accepts_sample_orders BOOLEAN DEFAULT true,
  sample_cost_usd DECIMAL(10,2),
  
  -- Communication
  chinese_language_support BOOLEAN DEFAULT true,
  english_language_support BOOLEAN DEFAULT false,
  french_language_support BOOLEAN DEFAULT false,
  wechat_id TEXT,
  whatsapp_number TEXT,
  alibaba_trade_assurance BOOLEAN DEFAULT false,
  
  -- Scoring interne
  internal_score INTEGER NOT NULL DEFAULT 50 CHECK (internal_score >= 0 AND internal_score <= 100),
  score_level TEXT NOT NULL DEFAULT 'UNVERIFIED' CHECK (score_level IN ('GOLD', 'SILVER', 'BRONZE', 'UNVERIFIED', 'BLACKLISTED')),
  successful_deliveries INTEGER DEFAULT 0,
  total_deliveries INTEGER DEFAULT 0,
  on_time_rate DECIMAL(5,2) DEFAULT 0 CHECK (on_time_rate >= 0 AND on_time_rate <= 100),
  dispute_rate DECIMAL(5,2) DEFAULT 0 CHECK (dispute_rate >= 0 AND dispute_rate <= 100),
  avg_response_time_hours DECIMAL(5,2) DEFAULT 24,
  
  -- Vérification admin
  verified_by_admin BOOLEAN DEFAULT false,
  verification_date TIMESTAMPTZ,
  verified_by UUID REFERENCES auth.users(id),
  notes TEXT,
  
  -- Métadonnées
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index pour optimisation
CREATE INDEX IF NOT EXISTS idx_china_suppliers_platform ON public.china_suppliers(platform_type);
CREATE INDEX IF NOT EXISTS idx_china_suppliers_score ON public.china_suppliers(internal_score DESC);
CREATE INDEX IF NOT EXISTS idx_china_suppliers_level ON public.china_suppliers(score_level);

-- ============================================================================
-- PARTIE 2: IMPORT PRODUITS CHINOIS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.china_product_imports (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  
  -- Source
  source_platform TEXT NOT NULL CHECK (source_platform IN ('ALIBABA', 'ALIEXPRESS', '1688', 'PRIVATE')),
  source_url TEXT NOT NULL,
  source_product_id TEXT,
  
  -- Infos produit
  original_title TEXT NOT NULL,
  translated_title TEXT,
  original_description TEXT,
  translated_description TEXT,
  images TEXT[] DEFAULT ARRAY[]::TEXT[],
  
  -- Prix et quantités
  supplier_price_cny DECIMAL(12,2) NOT NULL,
  supplier_price_usd DECIMAL(12,2) NOT NULL,
  moq INTEGER DEFAULT 1,
  price_tiers JSONB DEFAULT '[]'::JSONB,
  
  -- Variantes
  variants JSONB DEFAULT '[]'::JSONB,
  
  -- Délais
  production_time_days INTEGER DEFAULT 3,
  shipping_time_days INTEGER DEFAULT 15,
  
  -- Statut
  import_status TEXT NOT NULL DEFAULT 'pending' CHECK (import_status IN ('pending', 'imported', 'failed', 'archived')),
  import_error TEXT,
  
  -- Lien avec produit dropship final
  dropship_product_id UUID REFERENCES public.dropship_products(id) ON DELETE SET NULL,
  
  -- Métadonnées
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_china_imports_vendor ON public.china_product_imports(vendor_id);
CREATE INDEX IF NOT EXISTS idx_china_imports_status ON public.china_product_imports(import_status);

-- ============================================================================
-- PARTIE 3: COMMANDES FOURNISSEURS CHINOIS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.china_supplier_orders (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  customer_order_id UUID NOT NULL,
  vendor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  supplier_id UUID REFERENCES public.china_suppliers(id),
  
  -- Statut
  status TEXT NOT NULL DEFAULT 'pending_supplier_confirm' CHECK (status IN (
    'pending_supplier_confirm',
    'supplier_confirmed',
    'in_production',
    'quality_check',
    'ready_to_ship',
    'shipped_domestic_china',
    'at_consolidation_warehouse',
    'shipped_international',
    'customs_clearance',
    'last_mile_delivery',
    'delivered',
    'cancelled',
    'disputed'
  )),
  status_history JSONB DEFAULT '[]'::JSONB,
  
  -- Articles
  items JSONB NOT NULL DEFAULT '[]'::JSONB,
  
  -- Adresses
  shipping_address JSONB NOT NULL,
  billing_address JSONB,
  
  -- Instructions multilingues
  instructions_chinese TEXT,
  instructions_english TEXT,
  notes_internal TEXT,
  
  -- Montants
  supplier_total_cny DECIMAL(12,2) NOT NULL DEFAULT 0,
  supplier_total_usd DECIMAL(12,2) NOT NULL DEFAULT 0,
  shipping_cost_usd DECIMAL(10,2) DEFAULT 0,
  total_paid_supplier_usd DECIMAL(12,2) DEFAULT 0,
  
  -- Paiement fournisseur
  supplier_payment_status TEXT DEFAULT 'pending' CHECK (supplier_payment_status IN ('pending', 'partial', 'paid', 'refunded')),
  supplier_payment_reference TEXT,
  supplier_payment_date TIMESTAMPTZ,
  
  -- Délais
  expected_ship_date DATE,
  expected_delivery_date DATE,
  
  -- Métadonnées
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_china_orders_vendor ON public.china_supplier_orders(vendor_id);
CREATE INDEX IF NOT EXISTS idx_china_orders_status ON public.china_supplier_orders(status);
CREATE INDEX IF NOT EXISTS idx_china_orders_customer ON public.china_supplier_orders(customer_order_id);

-- ============================================================================
-- PARTIE 4: LOGISTIQUE CHINE
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.china_logistics (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  order_id UUID NOT NULL REFERENCES public.china_supplier_orders(id) ON DELETE CASCADE,
  
  -- Transport
  transport_method TEXT NOT NULL DEFAULT 'AIR' CHECK (transport_method IN ('AIR', 'SEA', 'EXPRESS', 'RAIL')),
  carrier_domestic TEXT, -- SF Express, YTO, etc.
  carrier_international TEXT, -- DHL, FedEx, etc.
  carrier_last_mile TEXT, -- Transporteur local
  
  -- Tracking multi-segments
  tracking_domestic TEXT,
  tracking_international TEXT,
  tracking_last_mile TEXT,
  
  -- Estimations (jours)
  estimated_production_days INTEGER DEFAULT 3,
  estimated_domestic_days INTEGER DEFAULT 2,
  estimated_customs_days INTEGER DEFAULT 3,
  estimated_international_days INTEGER DEFAULT 10,
  estimated_last_mile_days INTEGER DEFAULT 3,
  estimated_total_days INTEGER GENERATED ALWAYS AS (
    estimated_production_days + estimated_domestic_days + estimated_customs_days + 
    estimated_international_days + estimated_last_mile_days
  ) STORED,
  
  -- Dates réelles
  actual_ship_date TIMESTAMPTZ,
  actual_customs_date TIMESTAMPTZ,
  actual_delivery_date TIMESTAMPTZ,
  
  -- Douane
  customs_status TEXT DEFAULT 'pending' CHECK (customs_status IN ('pending', 'in_progress', 'cleared', 'held', 'released')),
  customs_reference TEXT,
  customs_duty_amount DECIMAL(10,2),
  customs_duty_currency TEXT DEFAULT 'USD',
  hs_code TEXT,
  
  -- Transparence client
  show_origin_to_customer BOOLEAN DEFAULT true,
  customer_estimated_min_days INTEGER,
  customer_estimated_max_days INTEGER,
  
  -- Métadonnées
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_china_logistics_order ON public.china_logistics(order_id);

-- ============================================================================
-- PARTIE 5: SYNCHRONISATION PRIX
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.china_price_syncs (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  product_id UUID NOT NULL REFERENCES public.china_product_imports(id) ON DELETE CASCADE,
  supplier_id UUID REFERENCES public.china_suppliers(id),
  
  -- Prix
  previous_price_cny DECIMAL(12,2) NOT NULL,
  current_price_cny DECIMAL(12,2) NOT NULL,
  previous_price_usd DECIMAL(12,2),
  current_price_usd DECIMAL(12,2),
  
  -- Changement
  price_change_percent DECIMAL(6,2),
  price_change_direction TEXT CHECK (price_change_direction IN ('up', 'down', 'stable')),
  
  -- Disponibilité
  previous_availability BOOLEAN DEFAULT true,
  current_availability BOOLEAN DEFAULT true,
  stock_quantity INTEGER,
  
  -- Alerte
  alert_generated BOOLEAN DEFAULT false,
  alert_type TEXT CHECK (alert_type IN ('INCREASE', 'DECREASE', 'OUT_OF_STOCK', 'BACK_IN_STOCK')),
  
  synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_china_price_syncs_product ON public.china_price_syncs(product_id);
CREATE INDEX IF NOT EXISTS idx_china_price_syncs_date ON public.china_price_syncs(synced_at DESC);

-- ============================================================================
-- PARTIE 6: ALERTES
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.china_price_alerts (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  product_id UUID REFERENCES public.china_product_imports(id) ON DELETE CASCADE,
  supplier_id UUID REFERENCES public.china_suppliers(id),
  
  alert_type TEXT NOT NULL CHECK (alert_type IN ('INCREASE', 'DECREASE', 'OUT_OF_STOCK', 'BACK_IN_STOCK')),
  severity TEXT NOT NULL DEFAULT 'medium' CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  
  -- Détails
  message TEXT NOT NULL,
  old_value DECIMAL(12,2),
  new_value DECIMAL(12,2),
  change_percent DECIMAL(6,2),
  
  -- Actions
  is_read BOOLEAN DEFAULT false,
  action_taken TEXT,
  auto_action_applied BOOLEAN DEFAULT false,
  
  -- Métadonnées
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_china_alerts_vendor ON public.china_price_alerts(vendor_id);
CREATE INDEX IF NOT EXISTS idx_china_alerts_unread ON public.china_price_alerts(vendor_id, is_read) WHERE is_read = false;

-- ============================================================================
-- PARTIE 7: SCORES FOURNISSEURS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.china_supplier_scores (
  supplier_id UUID PRIMARY KEY REFERENCES public.china_suppliers(id) ON DELETE CASCADE,
  
  -- Métriques
  delivery_success_rate DECIMAL(5,2) DEFAULT 0,
  on_time_delivery_rate DECIMAL(5,2) DEFAULT 0,
  quality_rating DECIMAL(3,2) DEFAULT 0,
  response_time_score DECIMAL(5,2) DEFAULT 0,
  dispute_resolution_score DECIMAL(5,2) DEFAULT 0,
  
  -- Historique
  total_orders INTEGER DEFAULT 0,
  successful_orders INTEGER DEFAULT 0,
  cancelled_orders INTEGER DEFAULT 0,
  disputed_orders INTEGER DEFAULT 0,
  
  -- Score global
  overall_score INTEGER DEFAULT 50 CHECK (overall_score >= 0 AND overall_score <= 100),
  score_level TEXT DEFAULT 'UNVERIFIED' CHECK (score_level IN ('GOLD', 'SILVER', 'BRONZE', 'UNVERIFIED', 'BLACKLISTED')),
  
  -- Alertes
  is_flagged BOOLEAN DEFAULT false,
  flag_reason TEXT,
  auto_disabled BOOLEAN DEFAULT false,
  
  last_calculated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- PARTIE 8: PARAMÈTRES VENDEUR
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.china_dropship_settings (
  vendor_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  
  -- Auto-sync
  auto_sync_prices BOOLEAN DEFAULT true,
  sync_frequency_hours INTEGER DEFAULT 24,
  
  -- Alertes
  price_increase_alert_threshold DECIMAL(5,2) DEFAULT 15.0,
  price_decrease_alert_threshold DECIMAL(5,2) DEFAULT 10.0,
  stock_alert_enabled BOOLEAN DEFAULT true,
  
  -- Auto-actions
  auto_disable_on_price_spike BOOLEAN DEFAULT true,
  auto_disable_threshold_percent DECIMAL(5,2) DEFAULT 30.0,
  auto_disable_on_stock_out BOOLEAN DEFAULT false,
  auto_disable_stock_out_days INTEGER DEFAULT 7,
  
  -- Affichage client
  show_origin_country BOOLEAN DEFAULT true,
  show_estimated_delivery BOOLEAN DEFAULT true,
  add_buffer_days INTEGER DEFAULT 3,
  
  -- Devise
  preferred_supplier_currency TEXT DEFAULT 'USD',
  local_selling_currency TEXT DEFAULT 'GNF',
  
  -- Métadonnées
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- PARTIE 9: LOGS CHINE
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.china_dropship_logs (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  
  log_type TEXT NOT NULL CHECK (log_type IN ('sync', 'import', 'order', 'alert', 'error', 'api')),
  severity TEXT NOT NULL DEFAULT 'info' CHECK (severity IN ('debug', 'info', 'warning', 'error', 'critical')),
  message TEXT NOT NULL,
  details JSONB,
  stack_trace TEXT,
  
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_china_logs_vendor ON public.china_dropship_logs(vendor_id);
CREATE INDEX IF NOT EXISTS idx_china_logs_type ON public.china_dropship_logs(log_type);
CREATE INDEX IF NOT EXISTS idx_china_logs_severity ON public.china_dropship_logs(severity);
CREATE INDEX IF NOT EXISTS idx_china_logs_date ON public.china_dropship_logs(created_at DESC);

-- ============================================================================
-- PARTIE 10: RAPPORTS CHINE
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.china_dropship_reports (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  
  report_period TEXT NOT NULL CHECK (report_period IN ('daily', 'weekly', 'monthly')),
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  
  -- Commandes
  total_china_orders INTEGER DEFAULT 0,
  completed_orders INTEGER DEFAULT 0,
  cancelled_orders INTEGER DEFAULT 0,
  disputed_orders INTEGER DEFAULT 0,
  
  -- Financier
  total_revenue_local DECIMAL(15,2) DEFAULT 0,
  total_cost_usd DECIMAL(15,2) DEFAULT 0,
  total_profit_local DECIMAL(15,2) DEFAULT 0,
  net_margin_percent DECIMAL(5,2) DEFAULT 0,
  
  -- Délais
  avg_actual_delivery_days DECIMAL(5,2),
  avg_estimated_delivery_days DECIMAL(5,2),
  delivery_variance_days DECIMAL(5,2),
  on_time_rate DECIMAL(5,2),
  
  -- Douane
  customs_blocked_orders INTEGER DEFAULT 0,
  customs_blocked_rate DECIMAL(5,2) DEFAULT 0,
  avg_customs_delay_days DECIMAL(5,2),
  
  -- Top performers
  top_suppliers JSONB DEFAULT '[]'::JSONB,
  top_products JSONB DEFAULT '[]'::JSONB,
  
  -- Problèmes
  price_increase_alerts INTEGER DEFAULT 0,
  stock_out_alerts INTEGER DEFAULT 0,
  quality_issues INTEGER DEFAULT 0,
  
  generated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_china_reports_vendor ON public.china_dropship_reports(vendor_id);
CREATE INDEX IF NOT EXISTS idx_china_reports_period ON public.china_dropship_reports(period_start DESC);

-- ============================================================================
-- PARTIE 11: EXTENSION dropship_products (colonne optionnelle)
-- ============================================================================

-- Ajouter colonne pour lier aux imports Chine (si pas déjà existante)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'dropship_products' AND column_name = 'china_import_id'
  ) THEN
    ALTER TABLE public.dropship_products 
    ADD COLUMN china_import_id UUID REFERENCES public.china_product_imports(id) ON DELETE SET NULL;
  END IF;
  
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'dropship_products' AND column_name = 'china_supplier_id'
  ) THEN
    ALTER TABLE public.dropship_products 
    ADD COLUMN china_supplier_id UUID REFERENCES public.china_suppliers(id) ON DELETE SET NULL;
  END IF;
END $$;

-- ============================================================================
-- PARTIE 12: RLS POLICIES
-- ============================================================================

-- Enable RLS
ALTER TABLE public.china_suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.china_product_imports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.china_supplier_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.china_logistics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.china_price_syncs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.china_price_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.china_supplier_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.china_dropship_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.china_dropship_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.china_dropship_reports ENABLE ROW LEVEL SECURITY;

-- Policies: china_suppliers (lecture publique, écriture admin)
DROP POLICY IF EXISTS "china_suppliers_read" ON public.china_suppliers;
CREATE POLICY "china_suppliers_read" ON public.china_suppliers
  FOR SELECT USING (true);

DROP POLICY IF EXISTS "china_suppliers_admin_write" ON public.china_suppliers;
CREATE POLICY "china_suppliers_admin_write" ON public.china_suppliers
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role::text IN ('admin', 'ceo'))
  );

-- Policies: china_product_imports (accès vendeur)
DROP POLICY IF EXISTS "china_imports_vendor_access" ON public.china_product_imports;
CREATE POLICY "china_imports_vendor_access" ON public.china_product_imports
  FOR ALL USING (auth.uid() = vendor_id);

-- Policies: china_supplier_orders (accès vendeur)
DROP POLICY IF EXISTS "china_orders_vendor_access" ON public.china_supplier_orders;
CREATE POLICY "china_orders_vendor_access" ON public.china_supplier_orders
  FOR ALL USING (auth.uid() = vendor_id);

-- Policies: china_logistics (via commande)
DROP POLICY IF EXISTS "china_logistics_vendor_access" ON public.china_logistics;
CREATE POLICY "china_logistics_vendor_access" ON public.china_logistics
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.china_supplier_orders WHERE id = order_id AND vendor_id = auth.uid())
  );

-- Policies: china_price_syncs (lecture via produit)
DROP POLICY IF EXISTS "china_price_syncs_read" ON public.china_price_syncs;
CREATE POLICY "china_price_syncs_read" ON public.china_price_syncs
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.china_product_imports WHERE id = product_id AND vendor_id = auth.uid())
  );

-- Policies: china_price_alerts (accès vendeur)
DROP POLICY IF EXISTS "china_alerts_vendor_access" ON public.china_price_alerts;
CREATE POLICY "china_alerts_vendor_access" ON public.china_price_alerts
  FOR ALL USING (auth.uid() = vendor_id);

-- Policies: china_supplier_scores (lecture publique)
DROP POLICY IF EXISTS "china_scores_read" ON public.china_supplier_scores;
CREATE POLICY "china_scores_read" ON public.china_supplier_scores
  FOR SELECT USING (true);

-- Policies: china_dropship_settings (accès vendeur)
DROP POLICY IF EXISTS "china_settings_vendor_access" ON public.china_dropship_settings;
CREATE POLICY "china_settings_vendor_access" ON public.china_dropship_settings
  FOR ALL USING (auth.uid() = vendor_id);

-- Policies: china_dropship_logs (accès vendeur + admin)
DROP POLICY IF EXISTS "china_logs_access" ON public.china_dropship_logs;
CREATE POLICY "china_logs_access" ON public.china_dropship_logs
  FOR ALL USING (
    vendor_id = auth.uid() OR 
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role::text IN ('admin', 'ceo'))
  );

-- Policies: china_dropship_reports (accès vendeur)
DROP POLICY IF EXISTS "china_reports_vendor_access" ON public.china_dropship_reports;
CREATE POLICY "china_reports_vendor_access" ON public.china_dropship_reports
  FOR ALL USING (auth.uid() = vendor_id);

-- ============================================================================
-- PARTIE 13: TRIGGERS
-- ============================================================================

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_china_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Appliquer aux tables
DROP TRIGGER IF EXISTS china_suppliers_updated_at ON public.china_suppliers;
CREATE TRIGGER china_suppliers_updated_at
  BEFORE UPDATE ON public.china_suppliers
  FOR EACH ROW EXECUTE FUNCTION update_china_updated_at();

DROP TRIGGER IF EXISTS china_product_imports_updated_at ON public.china_product_imports;
CREATE TRIGGER china_product_imports_updated_at
  BEFORE UPDATE ON public.china_product_imports
  FOR EACH ROW EXECUTE FUNCTION update_china_updated_at();

DROP TRIGGER IF EXISTS china_supplier_orders_updated_at ON public.china_supplier_orders;
CREATE TRIGGER china_supplier_orders_updated_at
  BEFORE UPDATE ON public.china_supplier_orders
  FOR EACH ROW EXECUTE FUNCTION update_china_updated_at();

DROP TRIGGER IF EXISTS china_logistics_updated_at ON public.china_logistics;
CREATE TRIGGER china_logistics_updated_at
  BEFORE UPDATE ON public.china_logistics
  FOR EACH ROW EXECUTE FUNCTION update_china_updated_at();

DROP TRIGGER IF EXISTS china_dropship_settings_updated_at ON public.china_dropship_settings;
CREATE TRIGGER china_dropship_settings_updated_at
  BEFORE UPDATE ON public.china_dropship_settings
  FOR EACH ROW EXECUTE FUNCTION update_china_updated_at();

-- ============================================================================
-- PARTIE 14: RAPPORT FINAL
-- ============================================================================

DO $$
DECLARE
  table_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO table_count
  FROM information_schema.tables 
  WHERE table_schema = 'public' 
  AND table_name LIKE 'china_%';
  
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE '🇨🇳 MODULE CHINA DROPSHIPPING - Installation terminée';
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE 'Tables créées: %', table_count;
  RAISE NOTICE '';
  RAISE NOTICE '✅ china_suppliers - Fournisseurs chinois';
  RAISE NOTICE '✅ china_product_imports - Import produits';
  RAISE NOTICE '✅ china_supplier_orders - Commandes fournisseurs';
  RAISE NOTICE '✅ china_logistics - Suivi logistique';
  RAISE NOTICE '✅ china_price_syncs - Sync prix';
  RAISE NOTICE '✅ china_price_alerts - Alertes prix';
  RAISE NOTICE '✅ china_supplier_scores - Scores fournisseurs';
  RAISE NOTICE '✅ china_dropship_settings - Paramètres';
  RAISE NOTICE '✅ china_dropship_logs - Logs';
  RAISE NOTICE '✅ china_dropship_reports - Rapports';
  RAISE NOTICE '';
  RAISE NOTICE '🔐 RLS Policies appliquées';
  RAISE NOTICE '⚡ Triggers updated_at configurés';
  RAISE NOTICE '════════════════════════════════════════════════════';
END $$;
