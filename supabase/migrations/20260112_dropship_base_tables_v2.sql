-- =============================================
-- DROPSHIP BASE TABLES - Migration de base (V2 - Robuste)
-- Tables fondamentales pour le système dropshipping
-- DOIT ÊTRE EXÉCUTÉE AVANT 20260112_china_dropshipping_module.sql
-- Date: 2026-01-12
-- Version: 2.0.0
-- 
-- ⚠️ Cette migration est idempotente et peut être réexécutée
-- =============================================

-- ============================================================================
-- PARTIE 1: TABLE DROPSHIP_SUPPLIERS
-- ============================================================================

-- Créer la table si elle n'existe pas
CREATE TABLE IF NOT EXISTS public.dropship_suppliers (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ajouter TOUTES les colonnes manquantes
DO $$
BEGIN
  -- company_name
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'company_name') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN company_name TEXT;
  END IF;
  -- email
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'email') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN email TEXT;
  END IF;
  -- phone
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'phone') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN phone TEXT;
  END IF;
  -- website
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'website') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN website TEXT;
  END IF;
  -- supplier_type
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'supplier_type') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN supplier_type TEXT DEFAULT 'international';
  END IF;
  -- country
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'country') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN country TEXT DEFAULT 'China';
  END IF;
  -- country_code
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'country_code') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN country_code TEXT DEFAULT 'CN';
  END IF;
  -- city
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'city') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN city TEXT;
  END IF;
  -- address
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'address') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN address TEXT;
  END IF;
  -- reliability_score
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'reliability_score') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN reliability_score DECIMAL(3,2) DEFAULT 0;
  END IF;
  -- total_orders
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'total_orders') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN total_orders INTEGER DEFAULT 0;
  END IF;
  -- successful_orders
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'successful_orders') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN successful_orders INTEGER DEFAULT 0;
  END IF;
  -- is_active
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'is_active') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN is_active BOOLEAN DEFAULT true;
  END IF;
  -- is_verified
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'is_verified') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN is_verified BOOLEAN DEFAULT false;
  END IF;
  -- verified_at
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'verified_at') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN verified_at TIMESTAMPTZ;
  END IF;
  -- verified_by
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'verified_by') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN verified_by UUID;
  END IF;
  -- has_api
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'has_api') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN has_api BOOLEAN DEFAULT false;
  END IF;
  -- api_endpoint
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'api_endpoint') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN api_endpoint TEXT;
  END IF;
  -- api_key_encrypted
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'api_key_encrypted') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN api_key_encrypted TEXT;
  END IF;
  -- api_type
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'api_type') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN api_type TEXT;
  END IF;
  -- default_currency
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'default_currency') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN default_currency TEXT DEFAULT 'USD';
  END IF;
  -- payment_terms
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'payment_terms') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN payment_terms TEXT DEFAULT 'prepaid';
  END IF;
  -- minimum_order_value
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'minimum_order_value') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN minimum_order_value DECIMAL(12,2) DEFAULT 0;
  END IF;
  -- contact_name
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'contact_name') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN contact_name TEXT;
  END IF;
  -- contact_phone
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'contact_phone') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN contact_phone TEXT;
  END IF;
  -- contact_email
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'contact_email') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN contact_email TEXT;
  END IF;
  -- wechat_id
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'wechat_id') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN wechat_id TEXT;
  END IF;
  -- whatsapp_number
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'whatsapp_number') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN whatsapp_number TEXT;
  END IF;
  -- notes
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'notes') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN notes TEXT;
  END IF;
  -- internal_notes
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'internal_notes') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN internal_notes TEXT;
  END IF;
  -- updated_at
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'updated_at') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();
  END IF;
  -- created_by
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers' AND column_name = 'created_by') THEN
    ALTER TABLE public.dropship_suppliers ADD COLUMN created_by UUID;
  END IF;
END $$;

-- Index (après les colonnes)
CREATE INDEX IF NOT EXISTS idx_dropship_suppliers_active ON public.dropship_suppliers(is_active);
CREATE INDEX IF NOT EXISTS idx_dropship_suppliers_type ON public.dropship_suppliers(supplier_type);
CREATE INDEX IF NOT EXISTS idx_dropship_suppliers_country ON public.dropship_suppliers(country_code);

-- ============================================================================
-- PARTIE 2: TABLE DROPSHIP_PRODUCTS
-- ============================================================================

-- Créer la table minimale si elle n'existe pas
CREATE TABLE IF NOT EXISTS public.dropship_products (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ajouter TOUTES les colonnes manquantes
DO $$
BEGIN
  -- supplier_id
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'supplier_id') THEN
    ALTER TABLE public.dropship_products ADD COLUMN supplier_id UUID;
  END IF;
  -- title
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'title') THEN
    ALTER TABLE public.dropship_products ADD COLUMN title TEXT;
  END IF;
  -- description
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'description') THEN
    ALTER TABLE public.dropship_products ADD COLUMN description TEXT;
  END IF;
  -- images
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'images') THEN
    ALTER TABLE public.dropship_products ADD COLUMN images TEXT[] DEFAULT ARRAY[]::TEXT[];
  END IF;
  -- thumbnail
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'thumbnail') THEN
    ALTER TABLE public.dropship_products ADD COLUMN thumbnail TEXT;
  END IF;
  -- category
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'category') THEN
    ALTER TABLE public.dropship_products ADD COLUMN category TEXT;
  END IF;
  -- subcategory
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'subcategory') THEN
    ALTER TABLE public.dropship_products ADD COLUMN subcategory TEXT;
  END IF;
  -- tags
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'tags') THEN
    ALTER TABLE public.dropship_products ADD COLUMN tags TEXT[] DEFAULT ARRAY[]::TEXT[];
  END IF;
  -- source_connector
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'source_connector') THEN
    ALTER TABLE public.dropship_products ADD COLUMN source_connector TEXT;
  END IF;
  -- source_product_id
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'source_product_id') THEN
    ALTER TABLE public.dropship_products ADD COLUMN source_product_id TEXT;
  END IF;
  -- source_url
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'source_url') THEN
    ALTER TABLE public.dropship_products ADD COLUMN source_url TEXT;
  END IF;
  -- source_sku
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'source_sku') THEN
    ALTER TABLE public.dropship_products ADD COLUMN source_sku TEXT;
  END IF;
  -- cost_price
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'cost_price') THEN
    ALTER TABLE public.dropship_products ADD COLUMN cost_price DECIMAL(12,2) DEFAULT 0;
  END IF;
  -- cost_currency
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'cost_currency') THEN
    ALTER TABLE public.dropship_products ADD COLUMN cost_currency TEXT DEFAULT 'USD';
  END IF;
  -- selling_price
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'selling_price') THEN
    ALTER TABLE public.dropship_products ADD COLUMN selling_price DECIMAL(15,2) DEFAULT 0;
  END IF;
  -- compare_at_price
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'compare_at_price') THEN
    ALTER TABLE public.dropship_products ADD COLUMN compare_at_price DECIMAL(15,2);
  END IF;
  -- margin_percent
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'margin_percent') THEN
    ALTER TABLE public.dropship_products ADD COLUMN margin_percent DECIMAL(5,2) DEFAULT 0;
  END IF;
  -- stock_quantity
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'stock_quantity') THEN
    ALTER TABLE public.dropship_products ADD COLUMN stock_quantity INTEGER DEFAULT 0;
  END IF;
  -- stock_status
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'stock_status') THEN
    ALTER TABLE public.dropship_products ADD COLUMN stock_status TEXT DEFAULT 'in_stock';
  END IF;
  -- track_stock
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'track_stock') THEN
    ALTER TABLE public.dropship_products ADD COLUMN track_stock BOOLEAN DEFAULT true;
  END IF;
  -- low_stock_threshold
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'low_stock_threshold') THEN
    ALTER TABLE public.dropship_products ADD COLUMN low_stock_threshold INTEGER DEFAULT 10;
  END IF;
  -- has_variants
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'has_variants') THEN
    ALTER TABLE public.dropship_products ADD COLUMN has_variants BOOLEAN DEFAULT false;
  END IF;
  -- variants
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'variants') THEN
    ALTER TABLE public.dropship_products ADD COLUMN variants JSONB DEFAULT '[]'::JSONB;
  END IF;
  -- auto_sync
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'auto_sync') THEN
    ALTER TABLE public.dropship_products ADD COLUMN auto_sync BOOLEAN DEFAULT true;
  END IF;
  -- sync_status
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'sync_status') THEN
    ALTER TABLE public.dropship_products ADD COLUMN sync_status TEXT DEFAULT 'never';
  END IF;
  -- last_sync_at
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'last_sync_at') THEN
    ALTER TABLE public.dropship_products ADD COLUMN last_sync_at TIMESTAMPTZ;
  END IF;
  -- last_sync_error
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'last_sync_error') THEN
    ALTER TABLE public.dropship_products ADD COLUMN last_sync_error TEXT;
  END IF;
  -- is_published
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'is_published') THEN
    ALTER TABLE public.dropship_products ADD COLUMN is_published BOOLEAN DEFAULT false;
  END IF;
  -- is_available
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'is_available') THEN
    ALTER TABLE public.dropship_products ADD COLUMN is_available BOOLEAN DEFAULT true;
  END IF;
  -- published_at
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'published_at') THEN
    ALTER TABLE public.dropship_products ADD COLUMN published_at TIMESTAMPTZ;
  END IF;
  -- shipping_time_min
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'shipping_time_min') THEN
    ALTER TABLE public.dropship_products ADD COLUMN shipping_time_min INTEGER DEFAULT 7;
  END IF;
  -- shipping_time_max
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'shipping_time_max') THEN
    ALTER TABLE public.dropship_products ADD COLUMN shipping_time_max INTEGER DEFAULT 21;
  END IF;
  -- weight_kg
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'weight_kg') THEN
    ALTER TABLE public.dropship_products ADD COLUMN weight_kg DECIMAL(8,3);
  END IF;
  -- rating
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'rating') THEN
    ALTER TABLE public.dropship_products ADD COLUMN rating DECIMAL(3,2) DEFAULT 0;
  END IF;
  -- review_count
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'review_count') THEN
    ALTER TABLE public.dropship_products ADD COLUMN review_count INTEGER DEFAULT 0;
  END IF;
  -- total_sold
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'total_sold') THEN
    ALTER TABLE public.dropship_products ADD COLUMN total_sold INTEGER DEFAULT 0;
  END IF;
  -- total_revenue
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'total_revenue') THEN
    ALTER TABLE public.dropship_products ADD COLUMN total_revenue DECIMAL(15,2) DEFAULT 0;
  END IF;
  -- is_premium
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'is_premium') THEN
    ALTER TABLE public.dropship_products ADD COLUMN is_premium BOOLEAN DEFAULT false;
  END IF;
  -- is_featured
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'is_featured') THEN
    ALTER TABLE public.dropship_products ADD COLUMN is_featured BOOLEAN DEFAULT false;
  END IF;
  -- metadata
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'metadata') THEN
    ALTER TABLE public.dropship_products ADD COLUMN metadata JSONB DEFAULT '{}'::JSONB;
  END IF;
  -- updated_at
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products' AND column_name = 'updated_at') THEN
    ALTER TABLE public.dropship_products ADD COLUMN updated_at TIMESTAMPTZ DEFAULT NOW();
  END IF;
END $$;

-- Index (après les colonnes)
CREATE INDEX IF NOT EXISTS idx_dropship_products_vendor ON public.dropship_products(vendor_id);
CREATE INDEX IF NOT EXISTS idx_dropship_products_supplier ON public.dropship_products(supplier_id);
CREATE INDEX IF NOT EXISTS idx_dropship_products_published ON public.dropship_products(is_published, is_available);
CREATE INDEX IF NOT EXISTS idx_dropship_products_category ON public.dropship_products(category);
CREATE INDEX IF NOT EXISTS idx_dropship_products_sync ON public.dropship_products(sync_status);
CREATE INDEX IF NOT EXISTS idx_dropship_products_source ON public.dropship_products(source_connector, source_product_id);

-- ============================================================================
-- PARTIE 3: TABLE DROPSHIP_ACTIVITY_LOGS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.dropship_activity_logs (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  action TEXT NOT NULL,
  details JSONB DEFAULT '{}'::JSONB,
  user_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_dropship_logs_entity ON public.dropship_activity_logs(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_dropship_logs_user ON public.dropship_activity_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_dropship_logs_date ON public.dropship_activity_logs(created_at DESC);

-- ============================================================================
-- PARTIE 4: FOREIGN KEYS (ajoutées séparément pour éviter erreurs)
-- ============================================================================

DO $$
BEGIN
  -- FK dropship_products.vendor_id -> auth.users
  IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints WHERE constraint_name = 'dropship_products_vendor_id_fkey') THEN
    BEGIN
      ALTER TABLE public.dropship_products ADD CONSTRAINT dropship_products_vendor_id_fkey FOREIGN KEY (vendor_id) REFERENCES auth.users(id) ON DELETE CASCADE;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'FK dropship_products_vendor_id_fkey skipped: %', SQLERRM;
    END;
  END IF;
  
  -- FK dropship_products.supplier_id -> dropship_suppliers
  IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints WHERE constraint_name = 'dropship_products_supplier_id_fkey') THEN
    BEGIN
      ALTER TABLE public.dropship_products ADD CONSTRAINT dropship_products_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.dropship_suppliers(id) ON DELETE SET NULL;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'FK dropship_products_supplier_id_fkey skipped: %', SQLERRM;
    END;
  END IF;
  
  -- FK dropship_suppliers.verified_by -> auth.users
  IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints WHERE constraint_name = 'dropship_suppliers_verified_by_fkey') THEN
    BEGIN
      ALTER TABLE public.dropship_suppliers ADD CONSTRAINT dropship_suppliers_verified_by_fkey FOREIGN KEY (verified_by) REFERENCES auth.users(id);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'FK dropship_suppliers_verified_by_fkey skipped: %', SQLERRM;
    END;
  END IF;
  
  -- FK dropship_suppliers.created_by -> auth.users
  IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints WHERE constraint_name = 'dropship_suppliers_created_by_fkey') THEN
    BEGIN
      ALTER TABLE public.dropship_suppliers ADD CONSTRAINT dropship_suppliers_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'FK dropship_suppliers_created_by_fkey skipped: %', SQLERRM;
    END;
  END IF;
  
  -- FK dropship_activity_logs.user_id -> auth.users
  IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints WHERE constraint_name = 'dropship_activity_logs_user_id_fkey') THEN
    BEGIN
      ALTER TABLE public.dropship_activity_logs ADD CONSTRAINT dropship_activity_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'FK dropship_activity_logs_user_id_fkey skipped: %', SQLERRM;
    END;
  END IF;
END $$;

-- ============================================================================
-- PARTIE 5: RLS POLICIES
-- ============================================================================

ALTER TABLE public.dropship_suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dropship_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dropship_activity_logs ENABLE ROW LEVEL SECURITY;

-- Policies: dropship_suppliers
DROP POLICY IF EXISTS "dropship_suppliers_read" ON public.dropship_suppliers;
CREATE POLICY "dropship_suppliers_read" ON public.dropship_suppliers
  FOR SELECT USING (
    is_active = true OR 
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role::text IN ('admin', 'ceo', 'vendor'))
  );

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
-- PARTIE 6: TRIGGERS
-- ============================================================================

CREATE OR REPLACE FUNCTION update_dropship_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS dropship_suppliers_updated_at ON public.dropship_suppliers;
CREATE TRIGGER dropship_suppliers_updated_at
  BEFORE UPDATE ON public.dropship_suppliers
  FOR EACH ROW EXECUTE FUNCTION update_dropship_updated_at();

DROP TRIGGER IF EXISTS dropship_products_updated_at ON public.dropship_products;
CREATE TRIGGER dropship_products_updated_at
  BEFORE UPDATE ON public.dropship_products
  FOR EACH ROW EXECUTE FUNCTION update_dropship_updated_at();

-- Trigger marge automatique
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
-- PARTIE 7: RAPPORT FINAL
-- ============================================================================

DO $$
DECLARE
  suppliers_count INTEGER;
  products_count INTEGER;
  logs_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO suppliers_count FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_suppliers';
  SELECT COUNT(*) INTO products_count FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_products';
  SELECT COUNT(*) INTO logs_count FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'dropship_activity_logs';
  
  RAISE NOTICE '';
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE '📦 DROPSHIP BASE TABLES V2 - Installation terminée';
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE '';
  RAISE NOTICE '✅ dropship_suppliers: % colonnes', suppliers_count;
  RAISE NOTICE '✅ dropship_products: % colonnes', products_count;
  RAISE NOTICE '✅ dropship_activity_logs: % colonnes', logs_count;
  RAISE NOTICE '';
  RAISE NOTICE '🔐 RLS Policies appliquées';
  RAISE NOTICE '⚡ Triggers configurés';
  RAISE NOTICE '🔗 Foreign Keys créées';
  RAISE NOTICE '';
  RAISE NOTICE '⚠️  Exécutez ensuite: 20260112_china_dropshipping_module.sql';
  RAISE NOTICE '════════════════════════════════════════════════════';
END $$;
