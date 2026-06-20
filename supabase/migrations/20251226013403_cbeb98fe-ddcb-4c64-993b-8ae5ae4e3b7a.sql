-- Table des produits numériques pour marketplace modulaire
CREATE TABLE public.digital_products (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  merchant_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  vendor_id UUID REFERENCES public.vendors(id) ON DELETE SET NULL,
  
  -- Informations produit
  title TEXT NOT NULL,
  description TEXT,
  short_description TEXT,
  images TEXT[] DEFAULT '{}',
  
  -- Catégorie et type
  category TEXT NOT NULL CHECK (category IN ('dropshipping', 'voyage', 'logiciel', 'formation', 'livre', 'custom')),
  product_mode TEXT NOT NULL DEFAULT 'direct' CHECK (product_mode IN ('direct', 'affiliate')),
  
  -- Prix et commission
  price NUMERIC NOT NULL DEFAULT 0,
  original_price NUMERIC,
  commission_rate NUMERIC DEFAULT 0,
  currency TEXT DEFAULT 'GNF',
  
  -- Affiliation
  affiliate_url TEXT,
  affiliate_platform TEXT,
  
  -- Dropshipping
  source_url TEXT,
  source_platform TEXT CHECK (source_platform IN ('amazon', 'aliexpress', 'alibaba', 'other', NULL)),
  
  -- Fichiers numériques (formation, livre, custom)
  file_urls TEXT[] DEFAULT '{}',
  file_type TEXT CHECK (file_type IN ('pdf', 'epub', 'video', 'audio', 'zip', 'other', NULL)),
  
  -- Métadonnées
  tags TEXT[] DEFAULT '{}',
  metadata JSONB DEFAULT '{}',
  
  -- Statut
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'pending', 'published', 'rejected', 'archived')),
  is_featured BOOLEAN DEFAULT false,
  is_premium BOOLEAN DEFAULT false,
  
  -- Statistiques
  views_count INTEGER DEFAULT 0,
  sales_count INTEGER DEFAULT 0,
  rating NUMERIC DEFAULT 0,
  reviews_count INTEGER DEFAULT 0,
  
  -- Timestamps
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  published_at TIMESTAMP WITH TIME ZONE
);

-- Index pour performance
CREATE INDEX idx_digital_products_merchant ON public.digital_products(merchant_id);
CREATE INDEX idx_digital_products_category ON public.digital_products(category);
CREATE INDEX idx_digital_products_status ON public.digital_products(status);
CREATE INDEX idx_digital_products_mode ON public.digital_products(product_mode);
CREATE INDEX idx_digital_products_published ON public.digital_products(published_at) WHERE status = 'published';

-- Enable RLS
ALTER TABLE public.digital_products ENABLE ROW LEVEL SECURITY;

-- Politiques RLS
-- Lecture publique des produits publiés
CREATE POLICY "Public can view published digital products"
ON public.digital_products
FOR SELECT
USING (status = 'published');

-- Marchands peuvent voir tous leurs produits
CREATE POLICY "Merchants can view their own digital products"
ON public.digital_products
FOR SELECT
TO authenticated
USING (merchant_id = auth.uid());

-- Marchands peuvent créer des produits
CREATE POLICY "Merchants can create digital products"
ON public.digital_products
FOR INSERT
TO authenticated
WITH CHECK (merchant_id = auth.uid());

-- Marchands peuvent modifier leurs produits
CREATE POLICY "Merchants can update their own digital products"
ON public.digital_products
FOR UPDATE
TO authenticated
USING (merchant_id = auth.uid())
WITH CHECK (merchant_id = auth.uid());

-- Marchands peuvent supprimer leurs produits
CREATE POLICY "Merchants can delete their own digital products"
ON public.digital_products
FOR DELETE
TO authenticated
USING (merchant_id = auth.uid());

-- Trigger pour updated_at
CREATE TRIGGER update_digital_products_updated_at
BEFORE UPDATE ON public.digital_products
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Table pour les achats de produits numériques
CREATE TABLE public.digital_product_purchases (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  product_id UUID NOT NULL REFERENCES public.digital_products(id) ON DELETE CASCADE,
  buyer_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  merchant_id UUID NOT NULL,
  
  -- Transaction
  amount NUMERIC NOT NULL,
  commission_amount NUMERIC DEFAULT 0,
  payment_status TEXT DEFAULT 'pending' CHECK (payment_status IN ('pending', 'completed', 'failed', 'refunded')),
  transaction_id TEXT,
  
  -- Accès
  access_granted BOOLEAN DEFAULT false,
  access_expires_at TIMESTAMP WITH TIME ZONE,
  download_count INTEGER DEFAULT 0,
  max_downloads INTEGER DEFAULT 5,
  
  -- Timestamps
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.digital_product_purchases ENABLE ROW LEVEL SECURITY;

-- Acheteurs peuvent voir leurs achats
CREATE POLICY "Buyers can view their purchases"
ON public.digital_product_purchases
FOR SELECT
TO authenticated
USING (buyer_id = auth.uid());

-- Marchands peuvent voir les ventes de leurs produits
CREATE POLICY "Merchants can view sales of their products"
ON public.digital_product_purchases
FOR SELECT
TO authenticated
USING (merchant_id = auth.uid());

-- Système peut créer des achats
CREATE POLICY "System can create purchases"
ON public.digital_product_purchases
FOR INSERT
TO authenticated
WITH CHECK (buyer_id = auth.uid());