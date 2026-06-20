-- =====================================================
-- EMERGENCY SOS SYSTEM - TABLES & FUNCTIONS
-- 224Solutions - Système d'alerte d'urgence taxi-moto
-- =====================================================

-- Table principale des alertes d'urgence
CREATE TABLE IF NOT EXISTS emergency_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  driver_name VARCHAR(255),
  driver_phone VARCHAR(20),
  driver_code VARCHAR(50),
  
  -- Statut de l'alerte
  status VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'in_progress', 'resolved', 'false_alert')),
  
  -- Position initiale
  initial_latitude DECIMAL(10, 8) NOT NULL,
  initial_longitude DECIMAL(11, 8) NOT NULL,
  initial_accuracy DECIMAL(10, 2),
  
  -- Position actuelle (mise à jour toutes les 2 secondes)
  current_latitude DECIMAL(10, 8),
  current_longitude DECIMAL(11, 8),
  current_accuracy DECIMAL(10, 2),
  current_speed DECIMAL(10, 2),
  current_direction DECIMAL(5, 2),
  
  -- Métadonnées
  silent_mode BOOLEAN DEFAULT false,
  bureau_syndicat_id UUID REFERENCES bureaus(id),
  handled_by UUID REFERENCES auth.users(id),
  handled_at TIMESTAMPTZ,
  resolution_notes TEXT,
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  resolved_at TIMESTAMPTZ,
  
  -- Index pour recherche rapide
  CONSTRAINT emergency_alerts_driver_id_idx UNIQUE (driver_id, created_at)
);

-- Index pour performances
CREATE INDEX idx_emergency_alerts_status ON emergency_alerts(status);
CREATE INDEX idx_emergency_alerts_driver ON emergency_alerts(driver_id);
CREATE INDEX idx_emergency_alerts_created ON emergency_alerts(created_at DESC);
CREATE INDEX idx_emergency_alerts_bureau ON emergency_alerts(bureau_syndicat_id);

-- Table de tracking GPS en temps réel (historique des positions)
CREATE TABLE IF NOT EXISTS emergency_gps_tracking (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_id UUID NOT NULL REFERENCES emergency_alerts(id) ON DELETE CASCADE,
  latitude DECIMAL(10, 8) NOT NULL,
  longitude DECIMAL(11, 8) NOT NULL,
  accuracy DECIMAL(10, 2),
  speed DECIMAL(10, 2),
  direction DECIMAL(5, 2),
  altitude DECIMAL(10, 2),
  timestamp TIMESTAMPTZ DEFAULT now(),
  
  -- Index pour recherche rapide par alerte
  CONSTRAINT emergency_gps_tracking_alert_idx UNIQUE (alert_id, timestamp)
);

CREATE INDEX idx_emergency_gps_alert ON emergency_gps_tracking(alert_id);
CREATE INDEX idx_emergency_gps_timestamp ON emergency_gps_tracking(timestamp DESC);

-- Table des actions prises par le syndicat
CREATE TABLE IF NOT EXISTS emergency_actions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_id UUID NOT NULL REFERENCES emergency_alerts(id) ON DELETE CASCADE,
  action_type VARCHAR(50) NOT NULL CHECK (action_type IN ('call_driver', 'send_message', 'notify_police', 'mark_safe', 'escalate', 'note')),
  performed_by UUID NOT NULL REFERENCES auth.users(id),
  performed_by_name VARCHAR(255),
  action_details JSONB,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_emergency_actions_alert ON emergency_actions(alert_id);
CREATE INDEX idx_emergency_actions_created ON emergency_actions(created_at DESC);

-- Fonction pour mettre à jour updated_at automatiquement
CREATE OR REPLACE FUNCTION update_emergency_alerts_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_emergency_alerts_timestamp
BEFORE UPDATE ON emergency_alerts
FOR EACH ROW
EXECUTE FUNCTION update_emergency_alerts_timestamp();

-- Fonction pour obtenir le dernier tracking GPS
CREATE OR REPLACE FUNCTION get_latest_gps_position(p_alert_id UUID)
RETURNS TABLE (
  latitude DECIMAL(10, 8),
  longitude DECIMAL(11, 8),
  speed DECIMAL(10, 2),
  direction DECIMAL(5, 2),
  timestamp TIMESTAMPTZ
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    egt.latitude,
    egt.longitude,
    egt.speed,
    egt.direction,
    egt.timestamp
  FROM emergency_gps_tracking egt
  WHERE egt.alert_id = p_alert_id
  ORDER BY egt.timestamp DESC
  LIMIT 1;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour obtenir les statistiques d'urgence par bureau
CREATE OR REPLACE FUNCTION get_emergency_stats_by_bureau(p_bureau_id UUID)
RETURNS TABLE (
  total_alerts BIGINT,
  active_alerts BIGINT,
  resolved_alerts BIGINT,
  false_alerts BIGINT,
  avg_resolution_time INTERVAL
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    COUNT(*)::BIGINT as total_alerts,
    COUNT(*) FILTER (WHERE status = 'active')::BIGINT as active_alerts,
    COUNT(*) FILTER (WHERE status = 'resolved')::BIGINT as resolved_alerts,
    COUNT(*) FILTER (WHERE status = 'false_alert')::BIGINT as false_alerts,
    AVG(resolved_at - created_at) FILTER (WHERE resolved_at IS NOT NULL) as avg_resolution_time
  FROM emergency_alerts
  WHERE bureau_syndicat_id = p_bureau_id;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- ROW LEVEL SECURITY (RLS)
-- =====================================================

ALTER TABLE emergency_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE emergency_gps_tracking ENABLE ROW LEVEL SECURITY;
ALTER TABLE emergency_actions ENABLE ROW LEVEL SECURITY;

-- Conducteurs peuvent créer et voir leurs propres alertes
CREATE POLICY "Drivers can create own alerts"
ON emergency_alerts FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = driver_id);

CREATE POLICY "Drivers can view own alerts"
ON emergency_alerts FOR SELECT
TO authenticated
USING (auth.uid() = driver_id);

CREATE POLICY "Drivers can update own active alerts"
ON emergency_alerts FOR UPDATE
TO authenticated
USING (auth.uid() = driver_id AND status = 'active');

-- Admins et syndicats peuvent tout voir
CREATE POLICY "Admins can view all alerts"
ON emergency_alerts FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role IN ('admin', 'syndicat')
  )
);

CREATE POLICY "Admins can update all alerts"
ON emergency_alerts FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role IN ('admin', 'syndicat')
  )
);

-- GPS Tracking policies
CREATE POLICY "System can insert GPS tracking"
ON emergency_gps_tracking FOR INSERT
TO authenticated
WITH CHECK (true);

CREATE POLICY "Users can view GPS tracking of their alerts"
ON emergency_gps_tracking FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM emergency_alerts ea
    WHERE ea.id = emergency_gps_tracking.alert_id
    AND (
      ea.driver_id = auth.uid()
      OR EXISTS (
        SELECT 1 FROM profiles
        WHERE profiles.id = auth.uid()
        AND profiles.role IN ('admin', 'syndicat')
      )
    )
  )
);

-- Actions policies
CREATE POLICY "Syndicats can create actions"
ON emergency_actions FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role IN ('admin', 'syndicat')
  )
);

CREATE POLICY "Users can view actions"
ON emergency_actions FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM emergency_alerts ea
    WHERE ea.id = emergency_actions.alert_id
    AND (
      ea.driver_id = auth.uid()
      OR EXISTS (
        SELECT 1 FROM profiles
        WHERE profiles.id = auth.uid()
        AND profiles.role IN ('admin', 'syndicat')
      )
    )
  )
);

-- =====================================================
-- NOTIFICATIONS REALTIME
-- =====================================================

-- Activer les notifications temps réel pour les alertes
ALTER PUBLICATION supabase_realtime ADD TABLE emergency_alerts;
ALTER PUBLICATION supabase_realtime ADD TABLE emergency_gps_tracking;
ALTER PUBLICATION supabase_realtime ADD TABLE emergency_actions;

-- =====================================================
-- VUES UTILES
-- =====================================================

-- Vue des alertes actives avec informations conducteur
CREATE OR REPLACE VIEW active_emergency_alerts AS
SELECT 
  ea.*,
  p.full_name as driver_full_name,
  p.avatar_url as driver_avatar,
  EXTRACT(EPOCH FROM (now() - ea.created_at)) as seconds_since_alert,
  (
    SELECT COUNT(*)
    FROM emergency_gps_tracking egt
    WHERE egt.alert_id = ea.id
  ) as tracking_points_count
FROM emergency_alerts ea
LEFT JOIN profiles p ON p.id = ea.driver_id
WHERE ea.status IN ('active', 'in_progress')
ORDER BY ea.created_at DESC;

-- Vue des statistiques globales
CREATE OR REPLACE VIEW emergency_global_stats AS
SELECT 
  COUNT(*) as total_alerts,
  COUNT(*) FILTER (WHERE status = 'active') as active_now,
  COUNT(*) FILTER (WHERE status = 'resolved') as resolved_today,
  COUNT(*) FILTER (WHERE status = 'false_alert') as false_alerts_today,
  AVG(EXTRACT(EPOCH FROM (resolved_at - created_at))) FILTER (WHERE resolved_at IS NOT NULL) as avg_resolution_seconds
FROM emergency_alerts
WHERE created_at >= CURRENT_DATE;

-- =====================================================
-- DONNÉES DE TEST (Optionnel - Supprimer en production)
-- =====================================================

-- Décommenter pour insérer des données de test
/*
INSERT INTO emergency_alerts (
  driver_id,
  driver_name,
  driver_phone,
  driver_code,
  initial_latitude,
  initial_longitude,
  status
) VALUES (
  (SELECT id FROM auth.users WHERE email = 'test@driver.com' LIMIT 1),
  'Mamadou Diallo',
  '+224 621 234 567',
  'DRV001',
  9.6412,
  -13.5784,
  'active'
);
*/
