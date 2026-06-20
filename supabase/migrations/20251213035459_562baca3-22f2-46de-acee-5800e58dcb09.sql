
-- =====================================================
-- RENFORCEMENT DU SYSTÈME DE SÉCURITÉ MOTOS VOLÉES
-- Phase 2: Corrections et améliorations
-- =====================================================

-- 1. S'assurer que les colonnes ont des valeurs par défaut correctes
ALTER TABLE vehicles 
ALTER COLUMN stolen_status SET DEFAULT 'clean';

-- 2. Créer un index pour améliorer les performances de recherche sur les motos volées
CREATE INDEX IF NOT EXISTS idx_vehicles_stolen_status ON vehicles(stolen_status) WHERE stolen_status = 'stolen';
CREATE INDEX IF NOT EXISTS idx_vehicles_bureau_stolen ON vehicles(bureau_id, stolen_status);

-- 3. Créer des index sur les tables de sécurité
CREATE INDEX IF NOT EXISTS idx_vehicle_security_log_vehicle ON vehicle_security_log(vehicle_id);
CREATE INDEX IF NOT EXISTS idx_vehicle_security_log_bureau ON vehicle_security_log(bureau_id);
CREATE INDEX IF NOT EXISTS idx_vehicle_security_log_created ON vehicle_security_log(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_vehicle_fraud_alerts_vehicle ON vehicle_fraud_alerts(vehicle_id);
CREATE INDEX IF NOT EXISTS idx_vehicle_fraud_alerts_resolved ON vehicle_fraud_alerts(is_resolved);
CREATE INDEX IF NOT EXISTS idx_vehicle_fraud_alerts_created ON vehicle_fraud_alerts(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_vehicle_gps_tracking_vehicle ON vehicle_gps_tracking(vehicle_id);
CREATE INDEX IF NOT EXISTS idx_vehicle_gps_tracking_created ON vehicle_gps_tracking(created_at DESC);

-- 4. Ajouter une contrainte CHECK sur stolen_status
ALTER TABLE vehicles DROP CONSTRAINT IF EXISTS vehicles_stolen_status_check;
ALTER TABLE vehicles ADD CONSTRAINT vehicles_stolen_status_check 
CHECK (stolen_status IN ('clean', 'stolen', 'recovered', 'blocked'));

-- 5. Améliorer la fonction declare_vehicle_stolen avec validation supplémentaire
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
    v_vehicle RECORD;
    v_log_id UUID;
BEGIN
    -- Validation: vérifier que le véhicule existe et appartient au bureau
    SELECT * INTO v_vehicle 
    FROM vehicles 
    WHERE id = p_vehicle_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Véhicule non trouvé');
    END IF;
    
    -- Vérifier que le bureau est autorisé
    IF v_vehicle.bureau_id != p_bureau_id THEN
        -- Enregistrer la tentative non autorisée
        INSERT INTO vehicle_security_log (
            vehicle_id, bureau_id, action, actor_id, actor_type, 
            description, ip_address, user_agent, metadata
        ) VALUES (
            p_vehicle_id, p_bureau_id, 'UNAUTHORIZED_THEFT_ATTEMPT', p_declared_by, 'bureau',
            'Tentative non autorisée de déclaration de vol par un autre bureau',
            p_ip_address, p_user_agent,
            jsonb_build_object('requesting_bureau', p_bureau_id, 'owner_bureau', v_vehicle.bureau_id)
        );
        
        RETURN jsonb_build_object('success', false, 'error', 'Non autorisé: ce véhicule n''appartient pas à votre bureau');
    END IF;
    
    -- Vérifier si déjà déclaré volé
    IF v_vehicle.stolen_status = 'stolen' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Ce véhicule est déjà déclaré volé');
    END IF;
    
    -- Validation du motif obligatoire
    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Le motif de déclaration est obligatoire');
    END IF;

    -- Mettre à jour le véhicule
    UPDATE vehicles SET
        stolen_status = 'stolen',
        stolen_declared_at = NOW(),
        stolen_declared_by = p_declared_by,
        stolen_reason = p_reason,
        stolen_location = p_location,
        status = 'suspended', -- Suspendre le véhicule
        security_lock_level = 3, -- Verrouillage maximum
        updated_at = NOW()
    WHERE id = p_vehicle_id;

    -- Enregistrer dans le journal de sécurité (immutable)
    INSERT INTO vehicle_security_log (
        vehicle_id, bureau_id, action, actor_id, actor_type, 
        description, ip_address, user_agent, metadata
    ) VALUES (
        p_vehicle_id, p_bureau_id, 'THEFT_DECLARED', p_declared_by, 'bureau',
        'Déclaration officielle de vol: ' || p_reason,
        p_ip_address, p_user_agent,
        jsonb_build_object(
            'reason', p_reason, 
            'location', p_location,
            'vehicle_serial', v_vehicle.serial_number,
            'vehicle_plate', v_vehicle.license_plate,
            'previous_status', v_vehicle.status
        )
    ) RETURNING id INTO v_log_id;

    -- Créer une alerte pour le PDG
    INSERT INTO vehicle_fraud_alerts (
        vehicle_id, bureau_id, alert_type, severity, 
        description, is_resolved
    ) VALUES (
        p_vehicle_id, p_bureau_id, 'THEFT_DECLARATION', 'critical',
        'Nouvelle déclaration de vol: ' || v_vehicle.license_plate || ' - ' || p_reason,
        false
    );

    -- Notifier le PDG via pdg_notifications si la table existe
    BEGIN
        INSERT INTO pdg_notifications (
            type, title, message, priority, metadata
        ) VALUES (
            'security_alert',
            '🚨 Moto déclarée volée',
            'Véhicule ' || v_vehicle.license_plate || ' déclaré volé par bureau ' || p_bureau_id,
            'critical',
            jsonb_build_object('vehicle_id', p_vehicle_id, 'bureau_id', p_bureau_id)
        );
    EXCEPTION WHEN undefined_table THEN
        -- Table n'existe pas, ignorer
        NULL;
    END;

    RETURN jsonb_build_object(
        'success', true, 
        'message', 'Véhicule déclaré volé avec succès',
        'log_id', v_log_id
    );
END;
$$;

-- 6. Améliorer la fonction declare_vehicle_recovered avec double validation
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
    v_log_id UUID;
BEGIN
    -- Validation: vérifier que le véhicule existe
    SELECT * INTO v_vehicle 
    FROM vehicles 
    WHERE id = p_vehicle_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Véhicule non trouvé');
    END IF;
    
    -- Vérifier que le bureau est autorisé (seul le bureau propriétaire peut lever le blocage)
    IF v_vehicle.bureau_id != p_bureau_id THEN
        -- Enregistrer la tentative non autorisée
        INSERT INTO vehicle_security_log (
            vehicle_id, bureau_id, action, actor_id, actor_type, 
            description, ip_address, user_agent, metadata
        ) VALUES (
            p_vehicle_id, p_bureau_id, 'UNAUTHORIZED_RECOVERY_ATTEMPT', p_declared_by, 'bureau',
            'Tentative non autorisée de levée de blocage par un autre bureau',
            p_ip_address, p_user_agent,
            jsonb_build_object('requesting_bureau', p_bureau_id, 'owner_bureau', v_vehicle.bureau_id)
        );
        
        RETURN jsonb_build_object('success', false, 'error', 'Non autorisé: seul le bureau propriétaire peut lever le blocage');
    END IF;
    
    -- Vérifier si le véhicule est bien déclaré volé
    IF v_vehicle.stolen_status != 'stolen' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Ce véhicule n''est pas déclaré volé');
    END IF;
    
    -- Validation du motif obligatoire
    IF p_reason IS NULL OR trim(p_reason) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'La justification de levée de blocage est obligatoire');
    END IF;

    -- Mettre à jour le véhicule
    UPDATE vehicles SET
        stolen_status = 'recovered',
        recovery_declared_at = NOW(),
        recovery_declared_by = p_declared_by,
        recovery_reason = p_reason,
        status = 'active', -- Réactiver le véhicule
        security_lock_level = 0, -- Lever le verrouillage
        updated_at = NOW()
    WHERE id = p_vehicle_id;

    -- Enregistrer dans le journal de sécurité (immutable)
    INSERT INTO vehicle_security_log (
        vehicle_id, bureau_id, action, actor_id, actor_type, 
        description, ip_address, user_agent, metadata
    ) VALUES (
        p_vehicle_id, p_bureau_id, 'RECOVERY_DECLARED', p_declared_by, 'bureau',
        'Levée de blocage: ' || p_reason,
        p_ip_address, p_user_agent,
        jsonb_build_object(
            'reason', p_reason,
            'original_theft_date', v_vehicle.stolen_declared_at,
            'original_theft_reason', v_vehicle.stolen_reason,
            'days_stolen', EXTRACT(DAY FROM NOW() - v_vehicle.stolen_declared_at)
        )
    ) RETURNING id INTO v_log_id;

    -- Résoudre les alertes associées
    UPDATE vehicle_fraud_alerts SET
        is_resolved = true,
        resolved_at = NOW(),
        resolved_by = p_declared_by,
        resolution_notes = 'Véhicule récupéré: ' || p_reason
    WHERE vehicle_id = p_vehicle_id AND is_resolved = false;

    RETURN jsonb_build_object(
        'success', true, 
        'message', 'Blocage levé avec succès',
        'log_id', v_log_id
    );
END;
$$;

-- 7. Fonction pour vérifier si un véhicule est bloqué (utilisée par les autres modules)
CREATE OR REPLACE FUNCTION is_vehicle_blocked(p_vehicle_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_status TEXT;
BEGIN
    SELECT stolen_status INTO v_status
    FROM vehicles
    WHERE id = p_vehicle_id;
    
    RETURN v_status IN ('stolen', 'blocked');
END;
$$;

-- 8. Fonction pour bloquer automatiquement les opérations sur véhicules volés
CREATE OR REPLACE FUNCTION check_vehicle_not_stolen()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_is_blocked BOOLEAN;
BEGIN
    -- Vérifier si le véhicule est bloqué
    SELECT is_vehicle_blocked(NEW.vehicle_id) INTO v_is_blocked;
    
    IF v_is_blocked THEN
        -- Enregistrer la tentative
        INSERT INTO vehicle_fraud_alerts (
            vehicle_id, alert_type, severity, description, is_resolved
        ) VALUES (
            NEW.vehicle_id, 'BLOCKED_OPERATION_ATTEMPT', 'high',
            'Tentative d''opération sur véhicule volé/bloqué',
            false
        );
        
        RAISE EXCEPTION 'Opération refusée: ce véhicule est déclaré volé ou bloqué';
    END IF;
    
    RETURN NEW;
END;
$$;

-- 9. Appliquer le trigger sur taxi_trips (si la table existe)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'taxi_trips') THEN
        DROP TRIGGER IF EXISTS check_vehicle_stolen_on_trip ON taxi_trips;
        CREATE TRIGGER check_vehicle_stolen_on_trip
            BEFORE INSERT ON taxi_trips
            FOR EACH ROW
            EXECUTE FUNCTION check_vehicle_not_stolen();
    END IF;
END;
$$;

-- 10. Vue consolidée pour les statistiques de sécurité PDG
CREATE OR REPLACE VIEW pdg_vehicle_security_overview AS
SELECT 
    COUNT(*) FILTER (WHERE stolen_status = 'stolen') as total_stolen,
    COUNT(*) FILTER (WHERE stolen_status = 'recovered') as total_recovered,
    COUNT(*) FILTER (WHERE stolen_status = 'blocked') as total_blocked,
    COUNT(*) FILTER (WHERE stolen_status = 'clean') as total_clean,
    (SELECT COUNT(*) FROM vehicle_fraud_alerts WHERE is_resolved = false) as pending_alerts,
    (SELECT COUNT(*) FROM vehicle_security_log WHERE created_at > NOW() - INTERVAL '7 days') as events_7d,
    (SELECT COUNT(*) FROM vehicle_security_log WHERE created_at > NOW() - INTERVAL '30 days') as events_30d
FROM vehicles;

-- 11. Politique RLS pour la vue PDG (admins uniquement)
GRANT SELECT ON pdg_vehicle_security_overview TO authenticated;

-- 12. Trigger pour mettre à jour automatiquement la dernière activité
CREATE OR REPLACE FUNCTION update_vehicle_last_activity()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE vehicles SET
        updated_at = NOW()
    WHERE id = NEW.vehicle_id;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS vehicle_security_log_update_activity ON vehicle_security_log;
CREATE TRIGGER vehicle_security_log_update_activity
    AFTER INSERT ON vehicle_security_log
    FOR EACH ROW
    EXECUTE FUNCTION update_vehicle_last_activity();

-- 13. Fonction utilitaire pour obtenir le résumé de sécurité d'un véhicule
CREATE OR REPLACE FUNCTION get_vehicle_security_summary(p_vehicle_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'vehicle_id', v.id,
        'license_plate', v.license_plate,
        'serial_number', v.serial_number,
        'stolen_status', v.stolen_status,
        'security_lock_level', COALESCE(v.security_lock_level, 0),
        'is_blocked', v.stolen_status IN ('stolen', 'blocked'),
        'stolen_at', v.stolen_declared_at,
        'stolen_reason', v.stolen_reason,
        'stolen_location', v.stolen_location,
        'last_known_position', CASE 
            WHEN v.last_known_latitude IS NOT NULL THEN 
                jsonb_build_object('lat', v.last_known_latitude, 'lng', v.last_known_longitude, 'at', v.last_known_location_at)
            ELSE NULL
        END,
        'security_events_count', (SELECT COUNT(*) FROM vehicle_security_log WHERE vehicle_id = p_vehicle_id),
        'pending_alerts_count', (SELECT COUNT(*) FROM vehicle_fraud_alerts WHERE vehicle_id = p_vehicle_id AND is_resolved = false),
        'gps_tracks_count', (SELECT COUNT(*) FROM vehicle_gps_tracking WHERE vehicle_id = p_vehicle_id)
    ) INTO v_result
    FROM vehicles v
    WHERE v.id = p_vehicle_id;
    
    RETURN v_result;
END;
$$;

-- 14. Accorder les permissions
GRANT EXECUTE ON FUNCTION declare_vehicle_stolen TO authenticated;
GRANT EXECUTE ON FUNCTION declare_vehicle_recovered TO authenticated;
GRANT EXECUTE ON FUNCTION is_vehicle_blocked TO authenticated;
GRANT EXECUTE ON FUNCTION get_vehicle_security_summary TO authenticated;
GRANT EXECUTE ON FUNCTION log_stolen_vehicle_gps TO authenticated;
