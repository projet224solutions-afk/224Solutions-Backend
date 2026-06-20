-- =====================================================
-- SYSTÈME DE SÉCURISATION MOTOS VOLÉES - MIGRATION
-- 224Solutions - Sécurité Institutionnelle
-- =====================================================

-- 1. Ajouter les colonnes de sécurité à la table vehicles
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS engine_number TEXT;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS stolen_status TEXT DEFAULT 'clean' CHECK (stolen_status IN ('clean', 'stolen', 'recovered', 'blocked'));
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS stolen_declared_at TIMESTAMPTZ;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS stolen_declared_by UUID;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS stolen_reason TEXT;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS stolen_location TEXT;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS last_known_latitude NUMERIC;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS last_known_longitude NUMERIC;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS last_known_location_at TIMESTAMPTZ;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS recovery_declared_at TIMESTAMPTZ;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS recovery_declared_by UUID;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS recovery_reason TEXT;
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS security_lock_level INTEGER DEFAULT 0;

-- 2. Créer la table de journal de sécurité inaltérable
CREATE TABLE IF NOT EXISTS vehicle_security_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vehicle_id UUID NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
    action TEXT NOT NULL CHECK (action IN (
        'THEFT_DECLARED', 
        'THEFT_BLOCKED', 
        'GPS_TRACKED', 
        'FRAUD_ATTEMPT', 
        'RECOVERY_DECLARED', 
        'REACTIVATION_REQUESTED',
        'REACTIVATION_APPROVED',
        'SUSPICIOUS_ACTIVITY',
        'DEVICE_CHANGE',
        'LOCATION_ANOMALY',
        'API_SUSPICIOUS'
    )),
    actor_id UUID,
    actor_type TEXT CHECK (actor_type IN ('bureau_syndicat', 'system', 'driver', 'pdg')),
    bureau_id UUID,
    description TEXT NOT NULL,
    metadata JSONB DEFAULT '{}',
    ip_address TEXT,
    user_agent TEXT,
    device_fingerprint TEXT,
    latitude NUMERIC,
    longitude NUMERIC,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- Index pour recherches rapides
CREATE INDEX IF NOT EXISTS idx_vehicle_security_log_vehicle ON vehicle_security_log(vehicle_id);
CREATE INDEX IF NOT EXISTS idx_vehicle_security_log_action ON vehicle_security_log(action);
CREATE INDEX IF NOT EXISTS idx_vehicle_security_log_created ON vehicle_security_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_vehicle_security_log_bureau ON vehicle_security_log(bureau_id);

-- 3. Créer la table des alertes de fraude détectées
CREATE TABLE IF NOT EXISTS vehicle_fraud_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vehicle_id UUID NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
    alert_type TEXT NOT NULL CHECK (alert_type IN (
        'REACTIVATION_ATTEMPT',
        'DEVICE_MISMATCH',
        'GPS_ANOMALY',
        'API_ABUSE',
        'PAYMENT_ATTEMPT',
        'TRIP_REQUEST',
        'DATA_MODIFICATION'
    )),
    severity TEXT NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
    description TEXT NOT NULL,
    detected_latitude NUMERIC,
    detected_longitude NUMERIC,
    metadata JSONB DEFAULT '{}',
    is_resolved BOOLEAN DEFAULT FALSE,
    resolved_at TIMESTAMPTZ,
    resolved_by UUID,
    resolution_notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_vehicle_fraud_alerts_vehicle ON vehicle_fraud_alerts(vehicle_id);
CREATE INDEX IF NOT EXISTS idx_vehicle_fraud_alerts_unresolved ON vehicle_fraud_alerts(is_resolved) WHERE is_resolved = FALSE;

-- 4. Créer la table de suivi GPS silencieux
CREATE TABLE IF NOT EXISTS vehicle_gps_tracking (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vehicle_id UUID NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
    latitude NUMERIC NOT NULL,
    longitude NUMERIC NOT NULL,
    accuracy NUMERIC,
    speed NUMERIC,
    heading NUMERIC,
    altitude NUMERIC,
    source TEXT CHECK (source IN ('driver_app', 'gps_device', 'cell_tower', 'wifi')),
    device_id TEXT,
    ip_address TEXT,
    is_stolen_vehicle BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_vehicle_gps_tracking_vehicle ON vehicle_gps_tracking(vehicle_id);
CREATE INDEX IF NOT EXISTS idx_vehicle_gps_tracking_stolen ON vehicle_gps_tracking(is_stolen_vehicle) WHERE is_stolen_vehicle = TRUE;
CREATE INDEX IF NOT EXISTS idx_vehicle_gps_tracking_created ON vehicle_gps_tracking(created_at DESC);

-- 5. Activer RLS sur les nouvelles tables
ALTER TABLE vehicle_security_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicle_fraud_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicle_gps_tracking ENABLE ROW LEVEL SECURITY;

-- 6. Politiques RLS - Journal de sécurité (lecture seule pour bureaux, PDG full access)
CREATE POLICY "Bureau peut voir logs de ses véhicules"
ON vehicle_security_log FOR SELECT
USING (
    bureau_id IN (
        SELECT id FROM bureaus WHERE access_token IS NOT NULL
    )
    OR EXISTS (
        SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
    )
);

CREATE POLICY "Service role full access security log"
ON vehicle_security_log FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- 7. Politiques RLS - Alertes fraude
CREATE POLICY "Bureau peut voir alertes de ses véhicules"
ON vehicle_fraud_alerts FOR SELECT
USING (
    vehicle_id IN (
        SELECT v.id FROM vehicles v WHERE v.bureau_id IN (
            SELECT id FROM bureaus WHERE access_token IS NOT NULL
        )
    )
    OR EXISTS (
        SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
    )
);

CREATE POLICY "Bureau peut résoudre alertes de ses véhicules"
ON vehicle_fraud_alerts FOR UPDATE
USING (
    vehicle_id IN (
        SELECT v.id FROM vehicles v WHERE v.bureau_id IN (
            SELECT id FROM bureaus WHERE access_token IS NOT NULL
        )
    )
);

CREATE POLICY "Service role full access fraud alerts"
ON vehicle_fraud_alerts FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- 8. Politiques RLS - GPS Tracking (Bureau ne voit que véhicules volés de son bureau)
CREATE POLICY "Bureau peut voir GPS de ses véhicules volés"
ON vehicle_gps_tracking FOR SELECT
USING (
    (
        vehicle_id IN (
            SELECT v.id FROM vehicles v 
            WHERE v.bureau_id IN (SELECT id FROM bureaus WHERE access_token IS NOT NULL)
            AND v.stolen_status = 'stolen'
        )
    )
    OR EXISTS (
        SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
    )
);

CREATE POLICY "Service role full access gps tracking"
ON vehicle_gps_tracking FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- 9. Fonction pour déclarer un véhicule volé
CREATE OR REPLACE FUNCTION declare_vehicle_stolen(
    p_vehicle_id UUID,
    p_bureau_id UUID,
    p_declared_by UUID,
    p_reason TEXT,
    p_location TEXT DEFAULT NULL,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result JSONB;
    v_vehicle RECORD;
BEGIN
    -- Vérifier que le véhicule existe et appartient au bureau
    SELECT * INTO v_vehicle FROM vehicles WHERE id = p_vehicle_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Véhicule non trouvé');
    END IF;
    
    IF v_vehicle.bureau_id != p_bureau_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'Véhicule n''appartient pas à ce bureau');
    END IF;
    
    IF v_vehicle.stolen_status = 'stolen' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Véhicule déjà déclaré volé');
    END IF;
    
    -- Mettre à jour le statut du véhicule
    UPDATE vehicles SET
        stolen_status = 'stolen',
        status = 'suspended',
        is_stolen = TRUE,
        stolen_declared_at = NOW(),
        stolen_declared_by = p_declared_by,
        stolen_reason = p_reason,
        stolen_location = p_location,
        security_lock_level = 10
    WHERE id = p_vehicle_id;
    
    -- Créer l'entrée dans le journal de sécurité
    INSERT INTO vehicle_security_log (
        vehicle_id, action, actor_id, actor_type, bureau_id,
        description, metadata, ip_address, user_agent
    ) VALUES (
        p_vehicle_id, 'THEFT_DECLARED', p_declared_by, 'bureau_syndicat', p_bureau_id,
        'Moto déclarée volée: ' || p_reason,
        jsonb_build_object(
            'location', p_location,
            'previous_status', v_vehicle.status,
            'serial_number', v_vehicle.serial_number,
            'license_plate', v_vehicle.license_plate
        ),
        p_ip_address, p_user_agent
    );
    
    -- Créer une notification pour le PDG
    INSERT INTO notifications (
        user_id, type, title, message, data, priority, created_at
    )
    SELECT 
        p.id,
        'VEHICLE_STOLEN',
        '🚨 ALERTE VOL - Moto déclarée volée',
        'Moto ' || COALESCE(v_vehicle.license_plate, v_vehicle.serial_number) || ' déclarée volée',
        jsonb_build_object('vehicle_id', p_vehicle_id, 'bureau_id', p_bureau_id),
        'urgent',
        NOW()
    FROM profiles p WHERE p.role = 'admin';
    
    RETURN jsonb_build_object(
        'success', true,
        'vehicle_id', p_vehicle_id,
        'message', 'Véhicule déclaré volé avec succès. Blocage global activé.'
    );
END;
$$;

-- 10. Fonction pour lever le blocage (avec validation)
CREATE OR REPLACE FUNCTION declare_vehicle_recovered(
    p_vehicle_id UUID,
    p_bureau_id UUID,
    p_declared_by UUID,
    p_reason TEXT,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_vehicle RECORD;
BEGIN
    SELECT * INTO v_vehicle FROM vehicles WHERE id = p_vehicle_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Véhicule non trouvé');
    END IF;
    
    IF v_vehicle.bureau_id != p_bureau_id THEN
        RETURN jsonb_build_object('success', false, 'error', 'Véhicule n''appartient pas à ce bureau');
    END IF;
    
    IF v_vehicle.stolen_status != 'stolen' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Véhicule n''est pas déclaré volé');
    END IF;
    
    -- Mettre à jour le statut
    UPDATE vehicles SET
        stolen_status = 'recovered',
        status = 'active',
        is_stolen = FALSE,
        recovery_declared_at = NOW(),
        recovery_declared_by = p_declared_by,
        recovery_reason = p_reason,
        security_lock_level = 0
    WHERE id = p_vehicle_id;
    
    -- Journal de sécurité
    INSERT INTO vehicle_security_log (
        vehicle_id, action, actor_id, actor_type, bureau_id,
        description, metadata, ip_address, user_agent
    ) VALUES (
        p_vehicle_id, 'RECOVERY_DECLARED', p_declared_by, 'bureau_syndicat', p_bureau_id,
        'Moto retrouvée: ' || p_reason,
        jsonb_build_object(
            'stolen_at', v_vehicle.stolen_declared_at,
            'recovery_time_hours', EXTRACT(EPOCH FROM (NOW() - v_vehicle.stolen_declared_at)) / 3600
        ),
        p_ip_address, p_user_agent
    );
    
    RETURN jsonb_build_object(
        'success', true,
        'vehicle_id', p_vehicle_id,
        'message', 'Véhicule réactivé avec succès.'
    );
END;
$$;

-- 11. Fonction pour enregistrer une activité GPS (mode furtif)
CREATE OR REPLACE FUNCTION log_stolen_vehicle_gps(
    p_vehicle_id UUID,
    p_latitude NUMERIC,
    p_longitude NUMERIC,
    p_accuracy NUMERIC DEFAULT NULL,
    p_speed NUMERIC DEFAULT NULL,
    p_device_id TEXT DEFAULT NULL,
    p_ip_address TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_vehicle RECORD;
BEGIN
    SELECT * INTO v_vehicle FROM vehicles WHERE id = p_vehicle_id;
    
    IF FOUND AND v_vehicle.stolen_status = 'stolen' THEN
        -- Enregistrer la position
        INSERT INTO vehicle_gps_tracking (
            vehicle_id, latitude, longitude, accuracy, speed,
            device_id, ip_address, is_stolen_vehicle
        ) VALUES (
            p_vehicle_id, p_latitude, p_longitude, p_accuracy, p_speed,
            p_device_id, p_ip_address, TRUE
        );
        
        -- Mettre à jour la dernière position connue
        UPDATE vehicles SET
            last_known_latitude = p_latitude,
            last_known_longitude = p_longitude,
            last_known_location_at = NOW()
        WHERE id = p_vehicle_id;
        
        -- Créer une alerte de fraude
        INSERT INTO vehicle_fraud_alerts (
            vehicle_id, alert_type, severity, description,
            detected_latitude, detected_longitude,
            metadata
        ) VALUES (
            p_vehicle_id, 'GPS_ANOMALY', 'critical',
            'Activité GPS détectée sur véhicule volé',
            p_latitude, p_longitude,
            jsonb_build_object('device_id', p_device_id, 'ip', p_ip_address)
        );
        
        -- Journal de sécurité
        INSERT INTO vehicle_security_log (
            vehicle_id, action, actor_type, description,
            latitude, longitude, metadata, ip_address
        ) VALUES (
            p_vehicle_id, 'GPS_TRACKED', 'system',
            'Position GPS détectée sur véhicule volé',
            p_latitude, p_longitude,
            jsonb_build_object('accuracy', p_accuracy, 'speed', p_speed),
            p_ip_address
        );
    END IF;
END;
$$;

-- 12. Vue pour statistiques de sécurité par bureau
CREATE OR REPLACE VIEW bureau_security_stats AS
SELECT 
    b.id AS bureau_id,
    b.bureau_code,
    b.commune,
    COUNT(v.id) FILTER (WHERE v.stolen_status = 'stolen') AS active_thefts,
    COUNT(v.id) FILTER (WHERE v.stolen_status = 'recovered') AS recovered_count,
    COUNT(vfa.id) FILTER (WHERE vfa.is_resolved = FALSE) AS pending_alerts,
    (
        SELECT COUNT(*) FROM vehicle_security_log vsl 
        WHERE vsl.bureau_id = b.id AND vsl.created_at > NOW() - INTERVAL '30 days'
    ) AS security_events_30d
FROM bureaus b
LEFT JOIN vehicles v ON v.bureau_id = b.id
LEFT JOIN vehicle_fraud_alerts vfa ON vfa.vehicle_id = v.id
GROUP BY b.id, b.bureau_code, b.commune;

-- 13. Enable Realtime on security tables
ALTER TABLE vehicle_security_log REPLICA IDENTITY FULL;
ALTER TABLE vehicle_fraud_alerts REPLICA IDENTITY FULL;
ALTER TABLE vehicle_gps_tracking REPLICA IDENTITY FULL;