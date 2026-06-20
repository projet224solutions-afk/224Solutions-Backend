-- =========================================
-- AMÉLIORATION SYSTÈME LIVREUR - Colonnes manquantes
-- Ajoute toutes les fonctionnalités demandées
-- =========================================

-- Améliorer la table drivers avec les colonnes manquantes
ALTER TABLE public.drivers ADD COLUMN IF NOT EXISTS full_name TEXT;
ALTER TABLE public.drivers ADD COLUMN IF NOT EXISTS phone_number TEXT;
ALTER TABLE public.drivers ADD COLUMN IF NOT EXISTS email TEXT;
ALTER TABLE public.drivers ADD COLUMN IF NOT EXISTS syndic_id UUID;
ALTER TABLE public.drivers ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'offline';
ALTER TABLE public.drivers ADD COLUMN IF NOT EXISTS earnings_total NUMERIC DEFAULT 0;
ALTER TABLE public.drivers ADD COLUMN IF NOT EXISTS commission_rate NUMERIC DEFAULT 1.5;
ALTER TABLE public.drivers ADD COLUMN IF NOT EXISTS last_location GEOGRAPHY(POINT);

-- Ajouter contrainte sur status si elle n'existe pas
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'drivers_status_check'
  ) THEN
    ALTER TABLE public.drivers ADD CONSTRAINT drivers_status_check 
    CHECK (status IN ('offline', 'online', 'on_delivery', 'paused'));
  END IF;
END $$;

-- Améliorer la table deliveries avec les colonnes manquantes
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS client_id UUID;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS price NUMERIC;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS driver_earning NUMERIC;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS start_time TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS end_time TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS proof_photo_url TEXT;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS client_signature TEXT;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS accepted_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS started_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS completed_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS cancel_reason TEXT;

-- Améliorer la table vehicles avec les colonnes manquantes
ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS registration_number TEXT;
ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS brand TEXT;
ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS model TEXT;
ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS chassis_number TEXT;
ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS photo_url TEXT;
ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS insurance_expiration DATE;
ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS tech_control_expiration DATE;
ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS is_stolen BOOLEAN DEFAULT FALSE;

-- Mettre à jour les données existantes des drivers
UPDATE public.drivers d
SET 
  full_name = COALESCE(p.first_name || ' ' || p.last_name, 'Livreur'),
  phone_number = COALESCE(p.phone, ''),
  email = COALESCE(p.email, ''),
  status = COALESCE(
    CASE 
      WHEN d.is_online = true THEN 'online'
      ELSE 'offline'
    END,
    'offline'
  )
FROM public.profiles p
WHERE d.user_id = p.id;

-- Calculer les gains pour les livraisons existantes (80% au livreur, 20% plateforme)
UPDATE public.deliveries
SET 
  driver_earning = delivery_fee * 0.80,
  price = delivery_fee,
  client_id = (SELECT customer_id FROM orders WHERE orders.id = deliveries.order_id LIMIT 1)
WHERE driver_earning IS NULL AND delivery_fee IS NOT NULL;

-- Créer des indexes pour les performances
CREATE INDEX IF NOT EXISTS idx_drivers_status ON public.drivers(status) WHERE status = 'online';
CREATE INDEX IF NOT EXISTS idx_drivers_location ON public.drivers USING GIST(last_location);
CREATE INDEX IF NOT EXISTS idx_deliveries_driver_status ON public.deliveries(driver_id, status);

-- Activer la réplication temps réel pour le tracking (sans IF NOT EXISTS)
DO $$ 
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.drivers;
  EXCEPTION
    WHEN duplicate_object THEN
      NULL;
  END;
END $$;

ALTER TABLE public.drivers REPLICA IDENTITY FULL;