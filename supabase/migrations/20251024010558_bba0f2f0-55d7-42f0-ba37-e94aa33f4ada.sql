-- MIGRATION SYSTÈME TAXI MOTO COMPLET - 224SOLUTIONS (CORRECTED)
-- Création des tables pour chauffeurs, documents KYC, configuration tarifaire

-- Table: Configuration de tarification
CREATE TABLE IF NOT EXISTS public.taxi_pricing_config (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  base_fare DECIMAL(10,2) DEFAULT 5000.00,
  per_km_rate DECIMAL(10,2) DEFAULT 2000.00,
  per_minute_rate DECIMAL(10,2) DEFAULT 100.00,
  minimum_fare DECIMAL(10,2) DEFAULT 7000.00,
  driver_commission DECIMAL(5,2) DEFAULT 85.00,
  platform_commission DECIMAL(5,2) DEFAULT 15.00,
  surge_multiplier DECIMAL(5,2) DEFAULT 1.00,
  currency VARCHAR(3) DEFAULT 'GNF',
  updated_at TIMESTAMPTZ DEFAULT now(),
  updated_by UUID REFERENCES auth.users(id)
);

-- Table: Documents KYC des chauffeurs
CREATE TABLE IF NOT EXISTS public.taxi_driver_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id UUID NOT NULL REFERENCES public.taxi_drivers(id) ON DELETE CASCADE,
  document_type VARCHAR(50) NOT NULL CHECK (document_type IN ('permis', 'carte_identite', 'assurance', 'carte_grise')),
  document_url TEXT NOT NULL,
  status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'in_review', 'approved', 'rejected')),
  uploaded_at TIMESTAMPTZ DEFAULT now(),
  verified_at TIMESTAMPTZ,
  verified_by UUID REFERENCES auth.users(id),
  rejection_reason TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Index pour optimiser les requêtes KYC
CREATE INDEX IF NOT EXISTS idx_taxi_driver_documents_driver ON public.taxi_driver_documents(driver_id);
CREATE INDEX IF NOT EXISTS idx_taxi_driver_documents_status ON public.taxi_driver_documents(status);

-- Ajouter les colonnes manquantes à taxi_drivers si elles n'existent pas
ALTER TABLE public.taxi_drivers 
  ADD COLUMN IF NOT EXISTS kyc_verified BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS can_work BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS last_heading DECIMAL(5,2),
  ADD COLUMN IF NOT EXISTS last_speed DECIMAL(5,2);

-- Table: Suivi des API costs (pour le calcul automatique PDG)
CREATE TABLE IF NOT EXISTS public.taxi_api_usage (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_type VARCHAR(50) NOT NULL CHECK (service_type IN ('mapbox_geocoding', 'mapbox_directions', 'google_maps')),
  request_count INTEGER DEFAULT 0,
  estimated_cost DECIMAL(10,6) DEFAULT 0,
  date DATE NOT NULL DEFAULT CURRENT_DATE,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(service_type, date)
);

-- Table: Historique des changements de tarification (audit)
CREATE TABLE IF NOT EXISTS public.taxi_pricing_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  config_snapshot JSONB NOT NULL,
  changed_by UUID REFERENCES auth.users(id),
  changed_at TIMESTAMPTZ DEFAULT now(),
  reason TEXT
);

-- Fonction: Incrémenter les gains d'un chauffeur
CREATE OR REPLACE FUNCTION increment_driver_earnings(
  p_driver_id UUID,
  p_amount DECIMAL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.taxi_drivers
  SET 
    total_earnings = COALESCE(total_earnings, 0) + p_amount,
    updated_at = now()
  WHERE id = p_driver_id;
END;
$$;

-- Fonction: Logger l'utilisation d'API
CREATE OR REPLACE FUNCTION log_api_usage(
  p_service_type VARCHAR,
  p_cost DECIMAL DEFAULT 0.001
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO public.taxi_api_usage (service_type, request_count, estimated_cost, date)
  VALUES (p_service_type, 1, p_cost, CURRENT_DATE)
  ON CONFLICT (service_type, date) 
  DO UPDATE SET 
    request_count = taxi_api_usage.request_count + 1,
    estimated_cost = taxi_api_usage.estimated_cost + p_cost;
END;
$$;

-- Trigger: Logger les changements de tarification
CREATE OR REPLACE FUNCTION log_pricing_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.taxi_pricing_history (config_snapshot, changed_by)
  VALUES (row_to_json(NEW), auth.uid());
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pricing_config_change_trigger ON public.taxi_pricing_config;
CREATE TRIGGER pricing_config_change_trigger
AFTER UPDATE ON public.taxi_pricing_config
FOR EACH ROW
EXECUTE FUNCTION log_pricing_change();

-- Insérer la configuration par défaut si elle n'existe pas
INSERT INTO public.taxi_pricing_config (id)
VALUES (gen_random_uuid())
ON CONFLICT DO NOTHING;

-- RLS Policies

-- taxi_pricing_config: lecture publique, modification admin seulement
ALTER TABLE public.taxi_pricing_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public can read pricing config" ON public.taxi_pricing_config;
CREATE POLICY "Public can read pricing config"
ON public.taxi_pricing_config FOR SELECT
USING (true);

DROP POLICY IF EXISTS "Admin can update pricing config" ON public.taxi_pricing_config;
CREATE POLICY "Admin can update pricing config"
ON public.taxi_pricing_config FOR UPDATE
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'::user_role
  )
);

-- taxi_driver_documents: chauffeur peut voir ses docs, admin peut tout voir
ALTER TABLE public.taxi_driver_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Drivers can view own documents" ON public.taxi_driver_documents;
CREATE POLICY "Drivers can view own documents"
ON public.taxi_driver_documents FOR SELECT
USING (driver_id = auth.uid() OR 
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'::user_role
  )
);

DROP POLICY IF EXISTS "Drivers can upload documents" ON public.taxi_driver_documents;
CREATE POLICY "Drivers can upload documents"
ON public.taxi_driver_documents FOR INSERT
WITH CHECK (driver_id = auth.uid());

DROP POLICY IF EXISTS "Admin can update documents" ON public.taxi_driver_documents;
CREATE POLICY "Admin can update documents"
ON public.taxi_driver_documents FOR UPDATE
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'::user_role
  )
);

-- taxi_api_usage: lecture admin seulement
ALTER TABLE public.taxi_api_usage ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin can view API usage" ON public.taxi_api_usage;
CREATE POLICY "Admin can view API usage"
ON public.taxi_api_usage FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'::user_role
  )
);

DROP POLICY IF EXISTS "System can insert API usage" ON public.taxi_api_usage;
CREATE POLICY "System can insert API usage"
ON public.taxi_api_usage FOR INSERT
WITH CHECK (true);

-- taxi_pricing_history: lecture admin seulement
ALTER TABLE public.taxi_pricing_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin can view pricing history" ON public.taxi_pricing_history;
CREATE POLICY "Admin can view pricing history"
ON public.taxi_pricing_history FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'::user_role
  )
);

-- Activer le realtime sur les nouvelles tables
ALTER PUBLICATION supabase_realtime ADD TABLE public.taxi_driver_documents;
ALTER PUBLICATION supabase_realtime ADD TABLE public.taxi_pricing_config;