-- 📦 TABLES DELIVERY - LIVRAISON
-- Tables pour gérer les notifications, tracking et logs de livraison

-- Table de notifications de livraison
CREATE TABLE IF NOT EXISTS delivery_notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('new_delivery', 'delivery_accepted', 'delivery_started', 'delivery_completed', 'delivery_cancelled')),
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  delivery_id UUID REFERENCES deliveries(id) ON DELETE SET NULL,
  read BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Table de tracking de livraison
CREATE TABLE IF NOT EXISTS delivery_tracking (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id UUID NOT NULL REFERENCES deliveries(id) ON DELETE CASCADE,
  driver_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  latitude DOUBLE PRECISION NOT NULL,
  longitude DOUBLE PRECISION NOT NULL,
  speed DOUBLE PRECISION,
  heading DOUBLE PRECISION,
  accuracy DOUBLE PRECISION,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Table de logs de livraison
CREATE TABLE IF NOT EXISTS delivery_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id UUID NOT NULL REFERENCES deliveries(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  action TEXT NOT NULL,
  metadata JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_delivery_notifications_user_id ON delivery_notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_delivery_notifications_read ON delivery_notifications(read);
CREATE INDEX IF NOT EXISTS idx_delivery_tracking_delivery_id ON delivery_tracking(delivery_id);
CREATE INDEX IF NOT EXISTS idx_delivery_tracking_recorded_at ON delivery_tracking(recorded_at);
CREATE INDEX IF NOT EXISTS idx_delivery_logs_delivery_id ON delivery_logs(delivery_id);

-- RLS Policies pour delivery_notifications
ALTER TABLE delivery_notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own delivery notifications"
ON delivery_notifications FOR SELECT
USING (auth.uid() = user_id);

CREATE POLICY "Service role can insert delivery notifications"
ON delivery_notifications FOR INSERT
WITH CHECK (auth.role() = 'service_role' OR auth.uid() = user_id);

CREATE POLICY "Users can update their own delivery notifications"
ON delivery_notifications FOR UPDATE
USING (auth.uid() = user_id);

-- RLS Policies pour delivery_tracking
ALTER TABLE delivery_tracking ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Drivers can view their own tracking"
ON delivery_tracking FOR SELECT
USING (auth.uid() = driver_id);

CREATE POLICY "Drivers can insert their own tracking"
ON delivery_tracking FOR INSERT
WITH CHECK (auth.uid() = driver_id);

-- RLS Policies pour delivery_logs
ALTER TABLE delivery_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view logs for their deliveries"
ON delivery_logs FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM deliveries
    WHERE deliveries.id = delivery_logs.delivery_id
    AND deliveries.driver_id = auth.uid()
  )
);

CREATE POLICY "Service role can insert delivery logs"
ON delivery_logs FOR INSERT
WITH CHECK (auth.role() = 'service_role' OR auth.uid() = user_id);

-- Activer realtime pour les notifications et tracking
ALTER PUBLICATION supabase_realtime ADD TABLE delivery_notifications;
ALTER PUBLICATION supabase_realtime ADD TABLE delivery_tracking;
