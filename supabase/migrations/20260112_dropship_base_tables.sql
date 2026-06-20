-- =============================================
-- DROPSHIP BASE TABLES - Migration de base
-- Tables fondamentales pour le système dropshipping
-- DOIT ÊTRE EXÉCUTÉE AVANT 20260112_china_dropshipping_module.sql
-- Date: 2026-01-12
-- Version: 1.0.0
-- 
-- ⚠️ PRÉREQUIS: Tables products et profiles doivent exister
-- =============================================

-- ============================================================================
-- PARTIE 1: TABLE DROPSHIP_SUPPLIERS (Fournisseurs de base)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.dropship_suppliers (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  
  -- Informations de base
  name TEXT NOT NULL,
  company_name TEXT,
  email TEXT,
  phone TEXT,
  website TEXT,
  
  -- Type et localisation
  supplier_type TEXT NOT NULL DEFAULT 'international' CHECK (supplier_type IN ('local', 'international', 'china')),
  country TEXT NOT NULL DEFAULT 'China',
  country_code TEXT DEFAULT 'CN',
  city TEXT,
  address TEXT,
  
  -- Fiabilité
  reliability_score DECIMAL(3,2) DEFAULT 0 CHECK (reliability_score >= 0 AND reliability_score <= 5),
  total_orders INTEGER DEFAULT 0,
  successful_orders INTEGER DEFAULT 0,
  
  -- Statut
  is_active BOOLEAN DEFAULT true,
  is_verified BOOLEAN DEFAULT false,
  verified_at TIMESTAMPTZ,
  verified_by UUID REFERENCES auth.users(id),
  
  -- API (pour fournisseurs avec intégration)
  has_api BOOLEAN DEFAULT false,
  api_endpoint TEXT,
  api_key_encrypted TEXT,
  api_type TEXT CHECK (api_type IN ('REST', 'SOAP', 'GraphQL', NULL)),
  
  -- Devise et paiement
  default_currency TEXT DEFAULT 'USD',
  payment_terms TEXT DEFAULT 'prepaid',
  minimum_order_value DECIMAL(12,2) DEFAULT 0,
  
  -- Contact
  contact_name TEXT,
  contact_phone TEXT,
  contact_email TEXT,
  wechat_id TEXT,
  whatsapp_number TEXT,
  
  -- Notes
  notes TEXT,
  internal_notes TEXT,
  
  -- Métadonnées
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by UUID REFERENCES auth.users(id)
);

-- Ajouter les colonnes manquantes si la table existe déjà
DO $$
BEGIN
  -- country_code
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_suppliers' AND column_name = 'country_code') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN country_code TEXT DEFAULT 'CN';
  END IF;
  -- city
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_suppliers' AND column_name = 'city') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN city TEXT;
  END IF;
  -- address
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_suppliers' AND column_name = 'address') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN address TEXT;
  END IF;
  -- wechat_id
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_suppliers' AND column_name = 'wechat_id') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN wechat_id TEXT;
  END IF;
  -- whatsapp_number
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_suppliers' AND column_name = 'whatsapp_number') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN whatsapp_number TEXT;
  END IF;
  -- internal_notes
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_suppliers' AND column_name = 'internal_notes') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN internal_notes TEXT;
  END IF;
END $$;

-- Index pour optimisation
CREATE INDEX IF NOT EXISTS idx_dropship_suppliers_active ON public.dropship_suppliers(is_active);
CREATE INDEX IF NOT EXISTS idx_dropship_suppliers_type ON public.dropship_suppliers(supplier_type);
CREATE INDEX IF NOT EXISTS idx_dropship_suppliers_country ON public.dropship_suppliers(country_code);

-- ============================================================================
-- PARTIE 2: TABLE DROPSHIP_PRODUCTS (Produits dropshipping)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.dropship_products (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  
  -- Relations
  vendor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  supplier_id UUID REFERENCES public.dropship_suppliers(id) ON DELETE SET NULL,
  
  -- Informations produit
  title TEXT NOT NULL,
  description TEXT,
  images TEXT[] DEFAULT ARRAY[]::TEXT[],
  thumbnail TEXT,
  category TEXT,
  subcategory TEXT,
  tags TEXT[] DEFAULT ARRAY[]::TEXT[],
  
  -- Source externe
  source_connector TEXT CHECK (source_connector IN ('ALIEXPRESS', 'ALIBABA', '1688', 'PRIVATE', 'OTHER')),
  source_product_id TEXT,
  source_url TEXT,
  source_sku TEXT,
  
  -- Prix
  cost_price DECIMAL(12,2) NOT NULL DEFAULT 0,
  cost_currency TEXT DEFAULT 'USD',
  selling_price DECIMAL(15,2) NOT NULL DEFAULT 0,
  compare_at_price DECIMAL(15,2),
  margin_percent DECIMAL(5,2) DEFAULT 0,
  
  -- Stock
  stock_quantity INTEGER DEFAULT 0,
  stock_status TEXT DEFAULT 'in_stock' CHECK (stock_status IN ('in_stock', 'low_stock', 'out_of_stock', 'unknown')),
  track_stock BOOLEAN DEFAULT true,
  low_stock_threshold INTEGER DEFAULT 10,
  
  -- Variantes
  has_variants BOOLEAN DEFAULT false,
  variants JSONB DEFAULT '[]'::JSONB,
  
  -- Synchronisation
  auto_sync BOOLEAN DEFAULT true,
  sync_status TEXT DEFAULT 'never' CHECK (sync_status IN ('synced', 'pending', 'error', 'never')),
  last_sync_at TIMESTAMPTZ,
  last_sync_error TEXT,
  
  -- Publication
  is_published BOOLEAN DEFAULT false,
  is_available BOOLEAN DEFAULT true,
  published_at TIMESTAMPTZ,
  
  -- Livraison
  shipping_time_min INTEGER DEFAULT 7,
  shipping_time_max INTEGER DEFAULT 21,
  weight_kg DECIMAL(8,3),
  
  -- Rating (copié ou calculé)
  rating DECIMAL(3,2) DEFAULT 0,
  review_count INTEGER DEFAULT 0,
  
  -- Statistiques de vente
  total_sold INTEGER DEFAULT 0,
  total_revenue DECIMAL(15,2) DEFAULT 0,
  
  -- Flags
  is_premium BOOLEAN DEFAULT false,
  is_featured BOOLEAN DEFAULT false,
  
  -- Métadonnées
  metadata JSONB DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ajouter les colonnes manquantes pour dropship_products si la table existe déjà
DO $$
BEGIN
  -- title
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'title') THEN
    ALTER TABLE public.dropship_products ADD COLUMN title TEXT;
  END IF;
  -- description
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'description') THEN
    ALTER TABLE public.dropship_products ADD COLUMN description TEXT;
  END IF;
  -- images
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'images') THEN
    ALTER TABLE public.dropship_products ADD COLUMN images TEXT[] DEFAULT ARRAY[]::TEXT[];
  END IF;
  -- thumbnail
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'thumbnail') THEN
    ALTER TABLE public.dropship_products ADD COLUMN thumbnail TEXT;
  END IF;
  -- category
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'category') THEN
    ALTER TABLE public.dropship_products ADD COLUMN category TEXT;
  END IF;
  -- subcategory
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'subcategory') THEN
    ALTER TABLE public.dropship_products ADD COLUMN subcategory TEXT;
  END IF;
  -- tags
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'tags') THEN
    ALTER TABLE public.dropship_products ADD COLUMN tags TEXT[] DEFAULT ARRAY[]::TEXT[];
  END IF;
  -- source_connector
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'source_connector') THEN
    ALTER TABLE public.dropship_products ADD COLUMN source_connector TEXT;
  END IF;
  -- source_product_id
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'source_product_id') THEN
    ALTER TABLE public.dropship_products ADD COLUMN source_product_id TEXT;
  END IF;
  -- source_url
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'source_url') THEN
    ALTER TABLE public.dropship_products ADD COLUMN source_url TEXT;
  END IF;
  -- source_sku
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'source_sku') THEN
    ALTER TABLE public.dropship_products ADD COLUMN source_sku TEXT;
  END IF;
  -- cost_price
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'cost_price') THEN
    ALTER TABLE public.dropship_products ADD COLUMN cost_price DECIMAL(12,2) DEFAULT 0;
  END IF;
  -- cost_currency
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'cost_currency') THEN
    ALTER TABLE public.dropship_products ADD COLUMN cost_currency TEXT DEFAULT 'USD';
  END IF;
  -- selling_price
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'selling_price') THEN
    ALTER TABLE public.dropship_products ADD COLUMN selling_price DECIMAL(15,2) DEFAULT 0;
  END IF;
  -- compare_at_price
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'compare_at_price') THEN
    ALTER TABLE public.dropship_products ADD COLUMN compare_at_price DECIMAL(15,2);
  END IF;
  -- margin_percent
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'margin_percent') THEN
    ALTER TABLE public.dropship_products ADD COLUMN margin_percent DECIMAL(5,2) DEFAULT 0;
  END IF;
  -- stock_quantity
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'stock_quantity') THEN
    ALTER TABLE public.dropship_products ADD COLUMN stock_quantity INTEGER DEFAULT 0;
  END IF;
  -- stock_status
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'stock_status') THEN
    ALTER TABLE public.dropship_products ADD COLUMN stock_status TEXT DEFAULT 'in_stock';
  END IF;
  -- track_stock
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'track_stock') THEN
    ALTER TABLE public.dropship_products ADD COLUMN track_stock BOOLEAN DEFAULT true;
  END IF;
  -- low_stock_threshold
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'low_stock_threshold') THEN
    ALTER TABLE public.dropship_products ADD COLUMN low_stock_threshold INTEGER DEFAULT 10;
  END IF;
  -- has_variants
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'has_variants') THEN
    ALTER TABLE public.dropship_products ADD COLUMN has_variants BOOLEAN DEFAULT false;
  END IF;
  -- variants
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'variants') THEN
    ALTER TABLE public.dropship_products ADD COLUMN variants JSONB DEFAULT '[]'::JSONB;
  END IF;
  -- auto_sync
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'auto_sync') THEN
    ALTER TABLE public.dropship_products ADD COLUMN auto_sync BOOLEAN DEFAULT true;
  END IF;
  -- sync_status
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'sync_status') THEN
    ALTER TABLE public.dropship_products ADD COLUMN sync_status TEXT DEFAULT 'never';
  END IF;
  -- last_sync_at
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'last_sync_at') THEN
    ALTER TABLE public.dropship_products ADD COLUMN last_sync_at TIMESTAMPTZ;
  END IF;
  -- last_sync_error
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'last_sync_error') THEN
    ALTER TABLE public.dropship_products ADD COLUMN last_sync_error TEXT;
  END IF;
  -- is_published
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'is_published') THEN
    ALTER TABLE public.dropship_products ADD COLUMN is_published BOOLEAN DEFAULT false;
  END IF;
  -- is_available
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'is_available') THEN
    ALTER TABLE public.dropship_products ADD COLUMN is_available BOOLEAN DEFAULT true;
  END IF;
  -- published_at
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'published_at') THEN
    ALTER TABLE public.dropship_products ADD COLUMN published_at TIMESTAMPTZ;
  END IF;
  -- shipping_time_min
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'shipping_time_min') THEN
    ALTER TABLE public.dropship_products ADD COLUMN shipping_time_min INTEGER DEFAULT 7;
  END IF;
  -- shipping_time_max
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'shipping_time_max') THEN
    ALTER TABLE public.dropship_products ADD COLUMN shipping_time_max INTEGER DEFAULT 21;
  END IF;
  -- weight_kg
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'weight_kg') THEN
    ALTER TABLE public.dropship_products ADD COLUMN weight_kg DECIMAL(8,3);
  END IF;
  -- rating
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'rating') THEN
    ALTER TABLE public.dropship_products ADD COLUMN rating DECIMAL(3,2) DEFAULT 0;
  END IF;
  -- review_count
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'review_count') THEN
    ALTER TABLE public.dropship_products ADD COLUMN review_count INTEGER DEFAULT 0;
  END IF;
  -- total_sold
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'total_sold') THEN
    ALTER TABLE public.dropship_products ADD COLUMN total_sold INTEGER DEFAULT 0;
  END IF;
  -- total_revenue
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'total_revenue') THEN
    ALTER TABLE public.dropship_products ADD COLUMN total_revenue DECIMAL(15,2) DEFAULT 0;
  END IF;
  -- is_premium
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'is_premium') THEN
    ALTER TABLE public.dropship_products ADD COLUMN is_premium BOOLEAN DEFAULT false;
  END IF;
  -- is_featured
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'is_featured') THEN
    ALTER TABLE public.dropship_products ADD COLUMN is_featured BOOLEAN DEFAULT false;
  END IF;
  -- metadata
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'metadata') THEN
    ALTER TABLE public.dropship_products ADD COLUMN metadata JSONB DEFAULT '{}'::JSONB;
  END IF;
  -- updated_at
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'dropship_products' AND column_name = 'updated_at') THEN
    ALTER TABLE public.dropship_products ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();
  END IF;
END $$;

-- Index pour optimisation
CREATE INDEX IF NOT EXISTS idx_dropship_products_vendor ON public.dropship_products(vendor_id);
CREATE INDEX IF NOT EXISTS idx_dropship_products_supplier ON public.dropship_products(supplier_id);
CREATE INDEX IF NOT EXISTS idx_dropship_products_published ON public.dropship_products(is_published, is_available);
CREATE INDEX IF NOT EXISTS idx_dropship_products_category ON public.dropship_products(category);
CREATE INDEX IF NOT EXISTS idx_dropship_products_sync ON public.dropship_products(sync_status);
CREATE INDEX IF NOT EXISTS idx_dropship_products_source ON public.dropship_products(source_connector, source_product_id);

-- ============================================================================
-- PARTIE 3: TABLE DROPSHIP_ACTIVITY_LOGS (Logs d'activité)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.dropship_activity_logs (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  
  -- Entité concernée
  entity_type TEXT NOT NULL CHECK (entity_type IN ('product', 'order', 'supplier', 'sync', 'import')),
  entity_id TEXT NOT NULL,
  
  -- Action
  action TEXT NOT NULL,
  details JSONB DEFAULT '{}'::JSONB,
  
  -- Utilisateur
  user_id UUID REFERENCES auth.users(id),
  
  -- Métadonnées
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index
CREATE INDEX IF NOT EXISTS idx_dropship_logs_entity ON public.dropship_activity_logs(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_dropship_logs_user ON public.dropship_activity_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_dropship_logs_date ON public.dropship_activity_logs(created_at DESC);

-- ============================================================================
-- PARTIE 4: RLS POLICIES
-- ============================================================================

-- Enable RLS
ALTER TABLE public.dropship_suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dropship_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dropship_activity_logs ENABLE ROW LEVEL SECURITY;

-- Policies: dropship_suppliers
DROP POLICY IF EXISTS "dropship_suppliers_read" ON public.dropship_suppliers;
CREATE POLICY "dropship_suppliers_read" ON public.dropship_suppliers
  FOR SELECT USING (is_active = true OR EXISTS (
    SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role::text IN ('admin', 'ceo', 'vendor')
  ));

DROP POLICY IF EXISTS "dropship_suppliers_admin_write" ON public.dropship_suppliers;
CREATE POLICY "dropship_suppliers_admin_write" ON public.dropship_suppliers
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role::text IN ('admin', 'ceo'))
  );

-- Policies: dropship_products
DROP POLICY IF EXISTS "dropship_products_vendor_access" ON public.dropship_products;
CREATE POLICY "dropship_products_vendor_access" ON public.dropship_products
  FOR ALL USING (
    vendor_id = auth.uid() OR 
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role::text IN ('admin', 'ceo'))
  );

DROP POLICY IF EXISTS "dropship_products_public_read" ON public.dropship_products;
CREATE POLICY "dropship_products_public_read" ON public.dropship_products
  FOR SELECT USING (is_published = true AND is_available = true);

-- Policies: dropship_activity_logs
DROP POLICY IF EXISTS "dropship_logs_access" ON public.dropship_activity_logs;
CREATE POLICY "dropship_logs_access" ON public.dropship_activity_logs
  FOR ALL USING (
    user_id = auth.uid() OR 
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role::text IN ('admin', 'ceo'))
  );

-- ============================================================================
-- PARTIE 5: TRIGGERS
-- ============================================================================

-- Fonction pour updated_at
CREATE OR REPLACE FUNCTION update_dropship_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers updated_at
DROP TRIGGER IF EXISTS dropship_suppliers_updated_at ON public.dropship_suppliers;
CREATE TRIGGER dropship_suppliers_updated_at
  BEFORE UPDATE ON public.dropship_suppliers
  FOR EACH ROW EXECUTE FUNCTION update_dropship_updated_at();

DROP TRIGGER IF EXISTS dropship_products_updated_at ON public.dropship_products;
CREATE TRIGGER dropship_products_updated_at
  BEFORE UPDATE ON public.dropship_products
  FOR EACH ROW EXECUTE FUNCTION update_dropship_updated_at();

-- Trigger pour calculer la marge automatiquement
CREATE OR REPLACE FUNCTION calculate_dropship_margin()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.cost_price > 0 AND NEW.selling_price > 0 THEN
    NEW.margin_percent = ((NEW.selling_price - NEW.cost_price) / NEW.cost_price) * 100;
  ELSE
    NEW.margin_percent = 0;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS dropship_products_margin ON public.dropship_products;
CREATE TRIGGER dropship_products_margin
  BEFORE INSERT OR UPDATE OF cost_price, selling_price ON public.dropship_products
  FOR EACH ROW EXECUTE FUNCTION calculate_dropship_margin();

-- ============================================================================
-- PARTIE 6: RAPPORT FINAL
-- ============================================================================

DO $$
BEGIN
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE '📦 DROPSHIP BASE TABLES - Installation terminée';
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE '';
  RAISE NOTICE '✅ dropship_suppliers - Table fournisseurs de base';
  RAISE NOTICE '✅ dropship_products - Table produits dropshipping';
  RAISE NOTICE '✅ dropship_activity_logs - Logs d''activité';
  RAISE NOTICE '';
  RAISE NOTICE '🔐 RLS Policies appliquées';
  RAISE NOTICE '⚡ Triggers updated_at et margin configurés';
  RAISE NOTICE '';
  RAISE NOTICE '⚠️  Exécutez ensuite: 20260112_china_dropshipping_module.sql';
  RAISE NOTICE '════════════════════════════════════════════════════';
END $$;
