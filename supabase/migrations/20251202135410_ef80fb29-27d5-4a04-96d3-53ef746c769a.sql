-- Ajouter les colonnes manquantes à la table deliveries pour le système complet
ALTER TABLE public.deliveries 
ADD COLUMN IF NOT EXISTS vendor_id uuid REFERENCES public.vendors(id),
ADD COLUMN IF NOT EXISTS vendor_name text,
ADD COLUMN IF NOT EXISTS vendor_phone text,
ADD COLUMN IF NOT EXISTS vendor_location jsonb,
ADD COLUMN IF NOT EXISTS customer_name text,
ADD COLUMN IF NOT EXISTS customer_phone text,
ADD COLUMN IF NOT EXISTS payment_method text DEFAULT 'prepaid' CHECK (payment_method IN ('prepaid', 'cod')),
ADD COLUMN IF NOT EXISTS package_type text DEFAULT 'standard',
ADD COLUMN IF NOT EXISTS package_description text,
ADD COLUMN IF NOT EXISTS distance_to_vendor numeric,
ADD COLUMN IF NOT EXISTS distance_vendor_to_client numeric,
ADD COLUMN IF NOT EXISTS total_distance numeric,
ADD COLUMN IF NOT EXISTS estimated_time_minutes integer,
ADD COLUMN IF NOT EXISTS driver_bonus numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS ready_for_pickup boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS ready_at timestamp with time zone;

-- Créer un index pour les requêtes de livraisons en attente par vendeur
CREATE INDEX IF NOT EXISTS idx_deliveries_vendor_pending 
ON public.deliveries(vendor_id, status) WHERE status = 'pending';

-- Créer un index pour les livraisons prêtes pour récupération
CREATE INDEX IF NOT EXISTS idx_deliveries_ready_for_pickup 
ON public.deliveries(ready_for_pickup, status) WHERE ready_for_pickup = true AND status = 'pending';

-- Créer la table delivery_offers pour gérer les offres aux livreurs
CREATE TABLE IF NOT EXISTS public.delivery_offers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id uuid NOT NULL REFERENCES public.deliveries(id) ON DELETE CASCADE,
  driver_id uuid NOT NULL,
  status text DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'refused', 'expired')),
  offered_at timestamp with time zone DEFAULT now(),
  responded_at timestamp with time zone,
  distance_to_vendor numeric,
  estimated_earnings numeric,
  expires_at timestamp with time zone DEFAULT (now() + interval '2 minutes'),
  created_at timestamp with time zone DEFAULT now()
);

-- Index pour les offres en attente
CREATE INDEX IF NOT EXISTS idx_delivery_offers_pending 
ON public.delivery_offers(driver_id, status) WHERE status = 'pending';

-- Enable RLS
ALTER TABLE public.delivery_offers ENABLE ROW LEVEL SECURITY;

-- Policies pour delivery_offers
CREATE POLICY "Drivers can view their own offers" ON public.delivery_offers
FOR SELECT USING (auth.uid() = driver_id);

CREATE POLICY "System can insert offers" ON public.delivery_offers
FOR INSERT WITH CHECK (true);

CREATE POLICY "Drivers can update their own offers" ON public.delivery_offers
FOR UPDATE USING (auth.uid() = driver_id);

-- Enable realtime for delivery_offers
ALTER PUBLICATION supabase_realtime ADD TABLE public.delivery_offers;