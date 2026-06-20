-- =====================================================
-- Migration 1: Détection de pays pour les agents
-- =====================================================

-- Ajouter les colonnes de détection géographique aux agents
ALTER TABLE public.agents_management 
ADD COLUMN IF NOT EXISTS detected_country TEXT,
ADD COLUMN IF NOT EXISTS detected_currency TEXT DEFAULT 'GNF',
ADD COLUMN IF NOT EXISTS detection_method TEXT, -- 'gps', 'sim', 'ip', 'manual'
ADD COLUMN IF NOT EXISTS detection_accuracy TEXT, -- 'high', 'medium', 'low'
ADD COLUMN IF NOT EXISTS country_code TEXT,
ADD COLUMN IF NOT EXISTS timezone TEXT,
ADD COLUMN IF NOT EXISTS last_location_update TIMESTAMP WITH TIME ZONE;

-- Index pour les recherches par pays
CREATE INDEX IF NOT EXISTS idx_agents_detected_country ON public.agents_management(detected_country);
CREATE INDEX IF NOT EXISTS idx_agents_country_code ON public.agents_management(country_code);

-- =====================================================
-- Migration 2: Multi-devises pour les wallets des agents
-- =====================================================

-- Ajouter le support multi-devises aux wallets des agents
ALTER TABLE public.agent_wallets
ADD COLUMN IF NOT EXISTS secondary_currencies JSONB DEFAULT '[]'::jsonb,
ADD COLUMN IF NOT EXISTS exchange_rates_cache JSONB DEFAULT '{}'::jsonb,
ADD COLUMN IF NOT EXISTS last_exchange_update TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS preferred_display_currency TEXT DEFAULT 'GNF';

-- Table pour l'historique des taux de change
CREATE TABLE IF NOT EXISTS public.currency_exchange_rates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  from_currency TEXT NOT NULL,
  to_currency TEXT NOT NULL,
  rate NUMERIC(20, 8) NOT NULL,
  source TEXT DEFAULT 'api', -- 'api', 'manual', 'central_bank'
  effective_date DATE NOT NULL DEFAULT CURRENT_DATE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE(from_currency, to_currency, effective_date)
);

-- Activer RLS sur currency_exchange_rates
ALTER TABLE public.currency_exchange_rates ENABLE ROW LEVEL SECURITY;

-- Politique de lecture publique pour les taux de change
CREATE POLICY "Anyone can view exchange rates" 
ON public.currency_exchange_rates 
FOR SELECT 
USING (true);

-- Index pour les taux de change
CREATE INDEX IF NOT EXISTS idx_exchange_rates_currencies ON public.currency_exchange_rates(from_currency, to_currency);
CREATE INDEX IF NOT EXISTS idx_exchange_rates_date ON public.currency_exchange_rates(effective_date DESC);

-- =====================================================
-- Migration 3: Frais adaptatifs par corridor de paiement
-- =====================================================

-- Table des corridors de paiement avec frais adaptatifs
CREATE TABLE IF NOT EXISTS public.payment_corridors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  corridor_name TEXT NOT NULL,
  source_country TEXT NOT NULL,
  source_currency TEXT NOT NULL,
  destination_country TEXT NOT NULL,
  destination_currency TEXT NOT NULL,
  
  -- Frais de base
  base_fee_percentage NUMERIC(5, 4) DEFAULT 0.02, -- 2% par défaut
  base_fee_fixed NUMERIC(15, 2) DEFAULT 0,
  
  -- Frais adaptatifs selon le montant
  fee_tiers JSONB DEFAULT '[
    {"min_amount": 0, "max_amount": 100000, "fee_percentage": 0.03},
    {"min_amount": 100001, "max_amount": 500000, "fee_percentage": 0.025},
    {"min_amount": 500001, "max_amount": 1000000, "fee_percentage": 0.02},
    {"min_amount": 1000001, "max_amount": null, "fee_percentage": 0.015}
  ]'::jsonb,
  
  -- Limites
  min_amount NUMERIC(15, 2) DEFAULT 1000,
  max_amount NUMERIC(15, 2) DEFAULT 100000000,
  daily_limit NUMERIC(15, 2) DEFAULT 50000000,
  
  -- Temps de traitement estimé (en minutes)
  estimated_processing_time INTEGER DEFAULT 5,
  
  -- Statut
  is_active BOOLEAN DEFAULT true,
  priority INTEGER DEFAULT 0, -- Pour le tri dans l'affichage
  
  -- Métadonnées
  payment_methods JSONB DEFAULT '["wallet", "bank", "mobile_money"]'::jsonb,
  description TEXT,
  terms_conditions TEXT,
  
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  
  UNIQUE(source_country, destination_country, source_currency, destination_currency)
);

-- Activer RLS
ALTER TABLE public.payment_corridors ENABLE ROW LEVEL SECURITY;

-- Politique de lecture publique pour les corridors
CREATE POLICY "Anyone can view active payment corridors" 
ON public.payment_corridors 
FOR SELECT 
USING (is_active = true);

-- Index pour les recherches de corridors
CREATE INDEX IF NOT EXISTS idx_corridors_source ON public.payment_corridors(source_country, source_currency);
CREATE INDEX IF NOT EXISTS idx_corridors_destination ON public.payment_corridors(destination_country, destination_currency);
CREATE INDEX IF NOT EXISTS idx_corridors_active ON public.payment_corridors(is_active) WHERE is_active = true;

-- Table pour l'historique des frais appliqués
CREATE TABLE IF NOT EXISTS public.corridor_fee_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  corridor_id UUID REFERENCES public.payment_corridors(id),
  transaction_id UUID,
  amount NUMERIC(15, 2) NOT NULL,
  fee_applied NUMERIC(15, 2) NOT NULL,
  fee_percentage_used NUMERIC(5, 4),
  source_currency TEXT NOT NULL,
  destination_currency TEXT NOT NULL,
  exchange_rate_used NUMERIC(20, 8),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Activer RLS
ALTER TABLE public.corridor_fee_history ENABLE ROW LEVEL SECURITY;

-- Les utilisateurs authentifiés peuvent voir leur historique de frais
CREATE POLICY "Users can view their fee history" 
ON public.corridor_fee_history 
FOR SELECT 
USING (auth.uid() IS NOT NULL);

-- Index pour l'historique
CREATE INDEX IF NOT EXISTS idx_fee_history_corridor ON public.corridor_fee_history(corridor_id);
CREATE INDEX IF NOT EXISTS idx_fee_history_date ON public.corridor_fee_history(created_at DESC);

-- Insérer quelques corridors par défaut (Afrique de l'Ouest)
INSERT INTO public.payment_corridors (corridor_name, source_country, source_currency, destination_country, destination_currency, base_fee_percentage, estimated_processing_time, priority)
VALUES 
  ('Guinée → Sénégal', 'GN', 'GNF', 'SN', 'XOF', 0.025, 5, 1),
  ('Guinée → Mali', 'GN', 'GNF', 'ML', 'XOF', 0.025, 5, 2),
  ('Guinée → Côte d''Ivoire', 'GN', 'GNF', 'CI', 'XOF', 0.025, 5, 3),
  ('Guinée → France', 'GN', 'GNF', 'FR', 'EUR', 0.035, 30, 10),
  ('Sénégal → Guinée', 'SN', 'XOF', 'GN', 'GNF', 0.025, 5, 1),
  ('Mali → Guinée', 'ML', 'XOF', 'GN', 'GNF', 0.025, 5, 2),
  ('Guinée interne', 'GN', 'GNF', 'GN', 'GNF', 0.015, 1, 0)
ON CONFLICT (source_country, destination_country, source_currency, destination_currency) DO NOTHING;

-- Insérer quelques taux de change par défaut
INSERT INTO public.currency_exchange_rates (from_currency, to_currency, rate, source)
VALUES 
  ('GNF', 'XOF', 0.058, 'manual'),
  ('XOF', 'GNF', 17.24, 'manual'),
  ('GNF', 'EUR', 0.000092, 'manual'),
  ('EUR', 'GNF', 10870, 'manual'),
  ('GNF', 'USD', 0.0001, 'manual'),
  ('USD', 'GNF', 10000, 'manual')
ON CONFLICT (from_currency, to_currency, effective_date) DO NOTHING;

-- Fonction pour calculer les frais d'un corridor
CREATE OR REPLACE FUNCTION public.calculate_corridor_fee(
  p_source_country TEXT,
  p_destination_country TEXT,
  p_source_currency TEXT,
  p_destination_currency TEXT,
  p_amount NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_corridor RECORD;
  v_tier RECORD;
  v_fee_percentage NUMERIC;
  v_fee_amount NUMERIC;
  v_exchange_rate NUMERIC;
  v_converted_amount NUMERIC;
BEGIN
  -- Trouver le corridor
  SELECT * INTO v_corridor
  FROM public.payment_corridors
  WHERE source_country = p_source_country
    AND destination_country = p_destination_country
    AND source_currency = p_source_currency
    AND destination_currency = p_destination_currency
    AND is_active = true
  LIMIT 1;
  
  IF v_corridor IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Corridor not found or inactive'
    );
  END IF;
  
  -- Vérifier les limites
  IF p_amount < v_corridor.min_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Amount below minimum: ' || v_corridor.min_amount
    );
  END IF;
  
  IF p_amount > v_corridor.max_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Amount above maximum: ' || v_corridor.max_amount
    );
  END IF;
  
  -- Trouver le tier de frais approprié
  v_fee_percentage := v_corridor.base_fee_percentage;
  
  FOR v_tier IN SELECT * FROM jsonb_array_elements(v_corridor.fee_tiers)
  LOOP
    IF p_amount >= (v_tier.value->>'min_amount')::NUMERIC 
       AND (v_tier.value->>'max_amount' IS NULL OR p_amount <= (v_tier.value->>'max_amount')::NUMERIC) THEN
      v_fee_percentage := (v_tier.value->>'fee_percentage')::NUMERIC;
      EXIT;
    END IF;
  END LOOP;
  
  -- Calculer les frais
  v_fee_amount := (p_amount * v_fee_percentage) + v_corridor.base_fee_fixed;
  
  -- Obtenir le taux de change
  SELECT rate INTO v_exchange_rate
  FROM public.currency_exchange_rates
  WHERE from_currency = p_source_currency
    AND to_currency = p_destination_currency
  ORDER BY effective_date DESC
  LIMIT 1;
  
  IF v_exchange_rate IS NULL THEN
    v_exchange_rate := 1;
  END IF;
  
  v_converted_amount := (p_amount - v_fee_amount) * v_exchange_rate;
  
  RETURN jsonb_build_object(
    'success', true,
    'corridor_id', v_corridor.id,
    'corridor_name', v_corridor.corridor_name,
    'source_amount', p_amount,
    'fee_percentage', v_fee_percentage,
    'fee_fixed', v_corridor.base_fee_fixed,
    'fee_total', v_fee_amount,
    'exchange_rate', v_exchange_rate,
    'destination_amount', v_converted_amount,
    'estimated_time_minutes', v_corridor.estimated_processing_time
  );
END;
$$;