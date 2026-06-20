-- TAXI-MOTO SYSTEM - 224Solutions Production Ready
-- Infrastructure complète avec locks, audit, paiements, notifications

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "postgis";

-- TABLES
CREATE TABLE IF NOT EXISTS public.taxi_drivers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL UNIQUE,
  is_online BOOLEAN DEFAULT FALSE,
  status TEXT DEFAULT 'offline',
  last_lat NUMERIC(10,7),
  last_lng NUMERIC(10,7),
  last_seen TIMESTAMPTZ DEFAULT NOW(),
  vehicle_type TEXT,
  vehicle_number TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.taxi_trips (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  customer_id UUID NOT NULL,
  driver_id UUID,
  pickup_lat NUMERIC(10,7),
  pickup_lng NUMERIC(10,7),
  dropoff_lat NUMERIC(10,7),
  dropoff_lng NUMERIC(10,7),
  pickup_address TEXT,
  dropoff_address TEXT,
  distance_km NUMERIC(10,2),
  duration_min INTEGER,
  price_total NUMERIC(10,2),
  driver_share NUMERIC(10,2),
  platform_fee NUMERIC(10,2),
  status TEXT DEFAULT 'requested',
  idempotency_key TEXT,
  declined_drivers UUID[] DEFAULT '{}',
  lock_version INTEGER DEFAULT 0,
  metadata JSONB DEFAULT '{}',
  requested_at TIMESTAMPTZ DEFAULT NOW(),
  accepted_at TIMESTAMPTZ,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS public.taxi_locks (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  resource_type TEXT NOT NULL,
  resource_id UUID NOT NULL,
  locked_by TEXT NOT NULL,
  locked_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  metadata JSONB DEFAULT '{}',
  UNIQUE(resource_type, resource_id)
);

CREATE TABLE IF NOT EXISTS public.taxi_audit_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  action_type TEXT NOT NULL,
  actor_id UUID,
  actor_type TEXT,
  resource_type TEXT NOT NULL,
  resource_id UUID,
  details JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.taxi_notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL,
  type TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  data JSONB DEFAULT '{}',
  is_read BOOLEAN DEFAULT FALSE,
  ride_id UUID,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  read_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS public.taxi_transactions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ride_id UUID NOT NULL,
  customer_id UUID NOT NULL,
  driver_id UUID,
  amount NUMERIC(10,2) NOT NULL,
  currency TEXT DEFAULT 'GNF',
  payment_method TEXT,
  payment_provider TEXT,
  provider_tx_id TEXT,
  status TEXT DEFAULT 'pending',
  driver_share NUMERIC(10,2),
  platform_fee NUMERIC(10,2),
  idempotency_key TEXT UNIQUE,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.taxi_ride_tracking (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ride_id UUID NOT NULL,
  driver_id UUID,
  latitude NUMERIC(10, 7) NOT NULL,
  longitude NUMERIC(10, 7) NOT NULL,
  timestamp TIMESTAMPTZ DEFAULT NOW()
);

-- FONCTIONS
CREATE OR REPLACE FUNCTION public.acquire_taxi_lock(
  p_resource_type TEXT, p_resource_id UUID, p_locked_by TEXT, p_ttl_seconds INTEGER DEFAULT 30
) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE lock_acquired BOOLEAN := FALSE;
BEGIN
  DELETE FROM public.taxi_locks WHERE expires_at < NOW();
  INSERT INTO public.taxi_locks (resource_type, resource_id, locked_by, expires_at)
  VALUES (p_resource_type, p_resource_id, p_locked_by, NOW() + (p_ttl_seconds || ' seconds')::INTERVAL)
  ON CONFLICT DO NOTHING RETURNING TRUE INTO lock_acquired;
  RETURN COALESCE(lock_acquired, FALSE);
END;
$$;

CREATE OR REPLACE FUNCTION public.release_taxi_lock(
  p_resource_type TEXT, p_resource_id UUID, p_locked_by TEXT
) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE rows_deleted INTEGER;
BEGIN
  DELETE FROM public.taxi_locks WHERE resource_type = p_resource_type AND resource_id = p_resource_id
    AND locked_by = p_locked_by AND expires_at > NOW();
  GET DIAGNOSTICS rows_deleted = ROW_COUNT;
  RETURN rows_deleted > 0;
END;
$$;

CREATE OR REPLACE FUNCTION public.log_taxi_action(
  p_action_type TEXT, p_actor_id UUID, p_actor_type TEXT, 
  p_resource_type TEXT, p_resource_id UUID, p_details JSONB DEFAULT '{}'
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE log_id UUID;
BEGIN
  INSERT INTO public.taxi_audit_logs (action_type, actor_id, actor_type, resource_type, resource_id, details)
  VALUES (p_action_type, p_actor_id, p_actor_type, p_resource_type, p_resource_id, p_details)
  RETURNING id INTO log_id;
  RETURN log_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_taxi_notification(
  p_user_id UUID, p_type TEXT, p_title TEXT, p_body TEXT, 
  p_data JSONB DEFAULT '{}', p_ride_id UUID DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE notif_id UUID;
BEGIN
  INSERT INTO public.taxi_notifications (user_id, type, title, body, data, ride_id)
  VALUES (p_user_id, p_type, p_title, p_body, p_data, p_ride_id) RETURNING id INTO notif_id;
  RETURN notif_id;
END;
$$;

-- RLS
ALTER TABLE public.taxi_drivers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.taxi_trips ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.taxi_locks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.taxi_audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.taxi_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.taxi_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.taxi_ride_tracking ENABLE ROW LEVEL SECURITY;

CREATE POLICY "taxi_drivers_service" ON public.taxi_drivers FOR ALL TO service_role USING (TRUE);
CREATE POLICY "taxi_trips_service" ON public.taxi_trips FOR ALL TO service_role USING (TRUE);
CREATE POLICY "taxi_locks_service" ON public.taxi_locks FOR ALL TO service_role USING (TRUE);
CREATE POLICY "taxi_audit_service" ON public.taxi_audit_logs FOR ALL TO service_role USING (TRUE);
CREATE POLICY "taxi_notif_service" ON public.taxi_notifications FOR ALL TO service_role USING (TRUE);
CREATE POLICY "taxi_tx_service" ON public.taxi_transactions FOR ALL TO service_role USING (TRUE);
CREATE POLICY "taxi_track_service" ON public.taxi_ride_tracking FOR ALL TO service_role USING (TRUE);

CREATE POLICY "drivers_read_self" ON public.taxi_drivers FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "notif_read_own" ON public.taxi_notifications FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "trips_read_involved" ON public.taxi_trips FOR SELECT 
  USING (auth.uid() = customer_id OR auth.uid() IN (SELECT user_id FROM taxi_drivers WHERE id = driver_id));