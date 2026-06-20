-- Création de la table des revenus PDG
CREATE TABLE IF NOT EXISTS public.revenus_pdg (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  source_type TEXT NOT NULL CHECK (source_type IN ('frais_transaction_wallet', 'frais_achat_commande')),
  transaction_id UUID,
  user_id UUID REFERENCES auth.users(id),
  service_id UUID,
  amount DECIMAL(12,2) NOT NULL,
  percentage_applied DECIMAL(5,2) NOT NULL,
  metadata JSONB,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Index pour performance
CREATE INDEX idx_revenus_pdg_source_type ON public.revenus_pdg(source_type);
CREATE INDEX idx_revenus_pdg_created_at ON public.revenus_pdg(created_at DESC);
CREATE INDEX idx_revenus_pdg_user_id ON public.revenus_pdg(user_id);

-- Activer RLS
ALTER TABLE public.revenus_pdg ENABLE ROW LEVEL SECURITY;

-- Policy : Seuls les admins peuvent voir les revenus
CREATE POLICY "Admins can view all revenus_pdg"
ON public.revenus_pdg
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'::user_role
  )
);

-- Policy : Le système peut insérer des revenus
CREATE POLICY "System can insert revenus_pdg"
ON public.revenus_pdg
FOR INSERT
WITH CHECK (true);

-- Création de la table des paramètres PDG
CREATE TABLE IF NOT EXISTS public.pdg_settings (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  setting_key TEXT NOT NULL UNIQUE,
  setting_value JSONB NOT NULL,
  description TEXT,
  updated_by UUID REFERENCES auth.users(id),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Activer RLS
ALTER TABLE public.pdg_settings ENABLE ROW LEVEL SECURITY;

-- Policy : Admins peuvent lire les paramètres
CREATE POLICY "Admins can view pdg_settings"
ON public.pdg_settings
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'::user_role
  )
);

-- Policy : Admins peuvent modifier les paramètres
CREATE POLICY "Admins can update pdg_settings"
ON public.pdg_settings
FOR UPDATE
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'::user_role
  )
);

-- Policy : Admins peuvent insérer des paramètres
CREATE POLICY "Admins can insert pdg_settings"
ON public.pdg_settings
FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'::user_role
  )
);

-- Insertion des paramètres par défaut
INSERT INTO public.pdg_settings (setting_key, setting_value, description)
VALUES 
  ('wallet_transaction_fee_percentage', '{"value": 1.5}'::jsonb, 'Pourcentage de frais sur les transactions wallet'),
  ('purchase_commission_percentage', '{"value": 10}'::jsonb, 'Pourcentage de commission sur les achats'),
  ('service_commissions', '{"boutique": 10, "restaurant": 8, "livraison": 5}'::jsonb, 'Commissions par type de service')
ON CONFLICT (setting_key) DO NOTHING;

-- Fonction pour enregistrer un revenu PDG
CREATE OR REPLACE FUNCTION public.record_pdg_revenue(
  p_source_type TEXT,
  p_amount DECIMAL,
  p_percentage DECIMAL,
  p_transaction_id UUID DEFAULT NULL,
  p_user_id UUID DEFAULT NULL,
  p_service_id UUID DEFAULT NULL,
  p_metadata JSONB DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_revenue_id UUID;
BEGIN
  INSERT INTO public.revenus_pdg (
    source_type,
    amount,
    percentage_applied,
    transaction_id,
    user_id,
    service_id,
    metadata
  ) VALUES (
    p_source_type,
    p_amount,
    p_percentage,
    p_transaction_id,
    p_user_id,
    p_service_id,
    p_metadata
  )
  RETURNING id INTO v_revenue_id;
  
  RETURN v_revenue_id;
END;
$$;

-- Fonction pour obtenir les statistiques des revenus PDG
CREATE OR REPLACE FUNCTION public.get_pdg_revenue_stats(
  p_start_date TIMESTAMP WITH TIME ZONE DEFAULT NULL,
  p_end_date TIMESTAMP WITH TIME ZONE DEFAULT NULL
)
RETURNS TABLE (
  total_revenue DECIMAL,
  wallet_fees_revenue DECIMAL,
  purchase_fees_revenue DECIMAL,
  transaction_count BIGINT,
  wallet_transaction_count BIGINT,
  purchase_transaction_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    COALESCE(SUM(amount), 0) as total_revenue,
    COALESCE(SUM(CASE WHEN source_type = 'frais_transaction_wallet' THEN amount ELSE 0 END), 0) as wallet_fees_revenue,
    COALESCE(SUM(CASE WHEN source_type = 'frais_achat_commande' THEN amount ELSE 0 END), 0) as purchase_fees_revenue,
    COUNT(*) as transaction_count,
    COUNT(*) FILTER (WHERE source_type = 'frais_transaction_wallet') as wallet_transaction_count,
    COUNT(*) FILTER (WHERE source_type = 'frais_achat_commande') as purchase_transaction_count
  FROM public.revenus_pdg
  WHERE 
    (p_start_date IS NULL OR created_at >= p_start_date)
    AND (p_end_date IS NULL OR created_at <= p_end_date);
END;
$$;