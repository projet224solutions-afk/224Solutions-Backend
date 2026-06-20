-- Créer une table pour la tarification dynamique
CREATE TABLE IF NOT EXISTS public.pricing_zones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  zone_name TEXT NOT NULL,
  coordinates GEOGRAPHY(POLYGON, 4326) NOT NULL,
  base_price NUMERIC NOT NULL DEFAULT 5000,
  price_per_km NUMERIC NOT NULL DEFAULT 1000,
  surge_multiplier NUMERIC DEFAULT 1.0,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table pour historique des prix
CREATE TABLE IF NOT EXISTS public.delivery_pricing (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id UUID REFERENCES public.deliveries(id) ON DELETE CASCADE,
  base_price NUMERIC NOT NULL,
  distance_price NUMERIC NOT NULL,
  surge_price NUMERIC DEFAULT 0,
  service_fee NUMERIC DEFAULT 0,
  total_price NUMERIC NOT NULL,
  currency TEXT DEFAULT 'GNF',
  pricing_details JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table pour les méthodes de paiement 224Solutions
CREATE TABLE IF NOT EXISTS public.payment_methods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  method_type TEXT NOT NULL, -- 'wallet', 'mobile_money', 'cash'
  provider TEXT, -- 'orange_money', 'mtn_money', '224solutions_wallet'
  phone_number TEXT,
  is_default BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  metadata JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.pricing_zones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_pricing ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_methods ENABLE ROW LEVEL SECURITY;

-- Policies pour pricing_zones
CREATE POLICY "Everyone can view active pricing zones"
  ON public.pricing_zones FOR SELECT
  USING (is_active = true);

CREATE POLICY "Admins can manage pricing zones"
  ON public.pricing_zones FOR ALL
  USING (has_role(auth.uid(), 'admin'::user_role));

-- Policies pour delivery_pricing
CREATE POLICY "Users can view their delivery pricing"
  ON public.delivery_pricing FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM deliveries d
      WHERE d.id = delivery_pricing.delivery_id
      AND (d.driver_id IN (SELECT id FROM drivers WHERE user_id = auth.uid())
           OR d.client_id = auth.uid())
    )
  );

CREATE POLICY "System can insert delivery pricing"
  ON public.delivery_pricing FOR INSERT
  WITH CHECK (true);

-- Policies pour payment_methods
CREATE POLICY "Users can manage their payment methods"
  ON public.payment_methods FOR ALL
  USING (user_id = auth.uid());

-- Indexes pour performance
CREATE INDEX IF NOT EXISTS idx_pricing_zones_active ON public.pricing_zones(is_active);
CREATE INDEX IF NOT EXISTS idx_delivery_pricing_delivery ON public.delivery_pricing(delivery_id);
CREATE INDEX IF NOT EXISTS idx_payment_methods_user ON public.payment_methods(user_id);
CREATE INDEX IF NOT EXISTS idx_payment_methods_default ON public.payment_methods(user_id, is_default) WHERE is_default = true;

-- Ajouter des zones de tarification pour Conakry
INSERT INTO public.pricing_zones (zone_name, coordinates, base_price, price_per_km, surge_multiplier)
VALUES 
  (
    'Kaloum',
    ST_GeomFromText('POLYGON((-13.7 9.5, -13.65 9.5, -13.65 9.55, -13.7 9.55, -13.7 9.5))', 4326),
    8000,
    1500,
    1.0
  ),
  (
    'Matam',
    ST_GeomFromText('POLYGON((-13.65 9.5, -13.6 9.5, -13.6 9.55, -13.65 9.55, -13.65 9.5))', 4326),
    7000,
    1200,
    1.0
  ),
  (
    'Ratoma',
    ST_GeomFromText('POLYGON((-13.65 9.55, -13.6 9.55, -13.6 9.6, -13.65 9.6, -13.65 9.55))', 4326),
    7000,
    1200,
    1.0
  )
ON CONFLICT DO NOTHING;

-- Fonction pour calculer le prix d'une livraison
CREATE OR REPLACE FUNCTION public.calculate_delivery_price(
  p_pickup_lat NUMERIC,
  p_pickup_lng NUMERIC,
  p_delivery_lat NUMERIC,
  p_delivery_lng NUMERIC
) RETURNS TABLE (
  base_price NUMERIC,
  distance_km NUMERIC,
  distance_price NUMERIC,
  surge_multiplier NUMERIC,
  total_price NUMERIC
) AS $$
DECLARE
  v_distance NUMERIC;
  v_base NUMERIC := 5000;
  v_price_per_km NUMERIC := 1000;
  v_surge NUMERIC := 1.0;
BEGIN
  -- Calculer la distance en km
  v_distance := ST_Distance(
    ST_SetSRID(ST_MakePoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
    ST_SetSRID(ST_MakePoint(p_delivery_lng, p_delivery_lat), 4326)::geography
  ) / 1000;

  -- Trouver la zone de tarification
  SELECT pz.base_price, pz.price_per_km, pz.surge_multiplier
  INTO v_base, v_price_per_km, v_surge
  FROM public.pricing_zones pz
  WHERE ST_Contains(
    pz.coordinates::geometry,
    ST_SetSRID(ST_MakePoint(p_pickup_lng, p_pickup_lat), 4326)
  )
  AND pz.is_active = true
  LIMIT 1;

  -- Retourner les détails du calcul
  RETURN QUERY SELECT
    v_base,
    v_distance,
    (v_distance * v_price_per_km),
    v_surge,
    ((v_base + (v_distance * v_price_per_km)) * v_surge)::NUMERIC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

COMMENT ON FUNCTION public.calculate_delivery_price IS 'Calcule le prix d''une livraison basé sur la distance et la zone';

-- Enable realtime for delivery updates
DO $$ 
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.deliveries;
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

DO $$ 
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.delivery_pricing;
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;