-- =====================================================
-- SYSTÈME DE SÉCURITÉ ET MONITORING COMPLET - 224SOLUTIONS
-- Migration: 20250101120000_security_monitoring_system_complete.sql
-- =====================================================

-- 1. TABLE PRINCIPALE DE MONITORING SÉCURITÉ
CREATE TABLE IF NOT EXISTS security_monitoring (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type VARCHAR(50) NOT NULL, -- 'login_attempt', 'api_call', 'transaction', 'system_error', 'attack_detected'
    severity_level VARCHAR(20) NOT NULL DEFAULT 'info', -- 'info', 'warning', 'critical', 'emergency'
    source_module VARCHAR(50) NOT NULL, -- 'auth', 'taxi_moto', 'syndicate', 'marketplace', 'payment', 'api'
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    ip_address INET,
    user_agent TEXT,
    event_data JSONB NOT NULL DEFAULT '{}',
    threat_level INTEGER DEFAULT 0, -- 0-10 (0=normal, 10=critique)
    status VARCHAR(20) DEFAULT 'active', -- 'active', 'resolved', 'investigating'
    auto_response_taken BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    resolved_at TIMESTAMP WITH TIME ZONE,
    resolved_by UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

-- 2. TABLE DES INCIDENTS DE SÉCURITÉ
CREATE TABLE IF NOT EXISTS security_incidents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    incident_id VARCHAR(20) UNIQUE NOT NULL, -- Format: INC-YYYY-XXXXX
    title VARCHAR(200) NOT NULL,
    description TEXT NOT NULL,
    incident_type VARCHAR(50) NOT NULL, -- 'attack', 'breach', 'fraud', 'system_failure', 'unauthorized_access'
    severity VARCHAR(20) NOT NULL, -- 'low', 'medium', 'high', 'critical'
    affected_modules TEXT[] DEFAULT '{}',
    affected_users UUID[] DEFAULT '{}',
    detection_method VARCHAR(50), -- 'automatic', 'manual', 'user_report', 'ai_analysis'
    response_actions JSONB DEFAULT '[]',
    status VARCHAR(20) DEFAULT 'open', -- 'open', 'investigating', 'resolved', 'closed'
    assigned_to UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    resolved_at TIMESTAMP WITH TIME ZONE
);

-- 3. TABLE DES ADRESSES IP BLOQUÉES
CREATE TABLE IF NOT EXISTS blocked_ips (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ip_address INET NOT NULL UNIQUE,
    reason VARCHAR(200) NOT NULL,
    blocked_by VARCHAR(50) DEFAULT 'auto_system', -- 'auto_system', 'manual', 'ai_detection'
    threat_score INTEGER DEFAULT 5, -- 1-10
    block_type VARCHAR(20) DEFAULT 'temporary', -- 'temporary', 'permanent'
    expires_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

-- 4. TABLE DES TENTATIVES DE CONNEXION
CREATE TABLE IF NOT EXISTS login_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255),
    ip_address INET NOT NULL,
    user_agent TEXT,
    success BOOLEAN NOT NULL,
    failure_reason VARCHAR(100),
    location_data JSONB DEFAULT '{}',
    device_info JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 5. TABLE DE MONITORING DES APIs
CREATE TABLE IF NOT EXISTS api_monitoring (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    api_provider VARCHAR(50) NOT NULL, -- 'mapbox', 'google_maps', 'stripe', 'mobile_money'
    endpoint VARCHAR(200) NOT NULL,
    method VARCHAR(10) NOT NULL,
    status_code INTEGER,
    response_time_ms INTEGER,
    request_size_bytes INTEGER,
    response_size_bytes INTEGER,
    error_message TEXT,
    rate_limit_remaining INTEGER,
    cost_estimate DECIMAL(10,4),
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 6. TABLE DES ALERTES SYSTÈME
CREATE TABLE IF NOT EXISTS system_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_id VARCHAR(20) UNIQUE NOT NULL, -- Format: ALT-YYYY-XXXXX
    title VARCHAR(200) NOT NULL,
    message TEXT NOT NULL,
    alert_type VARCHAR(50) NOT NULL, -- 'security', 'performance', 'api_limit', 'system_error', 'fraud'
    priority VARCHAR(20) NOT NULL DEFAULT 'medium', -- 'low', 'medium', 'high', 'urgent'
    target_users UUID[] DEFAULT '{}', -- PDG, admins spécifiques
    channels VARCHAR(50)[] DEFAULT '{}', -- 'email', 'push', 'sms', 'dashboard'
    status VARCHAR(20) DEFAULT 'active', -- 'active', 'acknowledged', 'resolved'
    auto_resolve BOOLEAN DEFAULT false,
    resolve_after_minutes INTEGER,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    acknowledged_at TIMESTAMP WITH TIME ZONE,
    acknowledged_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    resolved_at TIMESTAMP WITH TIME ZONE
);

-- 7. TABLE DES ACTIONS AUTOMATIQUES
CREATE TABLE IF NOT EXISTS automated_responses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trigger_event VARCHAR(50) NOT NULL,
    condition_rules JSONB NOT NULL,
    action_type VARCHAR(50) NOT NULL, -- 'block_ip', 'disable_user', 'isolate_service', 'send_alert', 'restart_service'
    action_config JSONB NOT NULL,
    is_active BOOLEAN DEFAULT true,
    execution_count INTEGER DEFAULT 0,
    last_executed TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

-- 8. TABLE DES AUDITS DE SÉCURITÉ
CREATE TABLE IF NOT EXISTS security_audits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    audit_id VARCHAR(20) UNIQUE NOT NULL, -- Format: AUD-YYYY-XXXXX
    audit_type VARCHAR(50) NOT NULL, -- 'user_action', 'system_change', 'data_access', 'permission_change'
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    target_resource VARCHAR(100),
    action_performed VARCHAR(100) NOT NULL,
    old_values JSONB DEFAULT '{}',
    new_values JSONB DEFAULT '{}',
    ip_address INET,
    user_agent TEXT,
    session_id VARCHAR(100),
    risk_score INTEGER DEFAULT 0, -- 0-10
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 9. TABLE DES CONFIGURATIONS DE SÉCURITÉ
CREATE TABLE IF NOT EXISTS security_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    setting_key VARCHAR(100) UNIQUE NOT NULL,
    setting_value JSONB NOT NULL,
    description TEXT,
    category VARCHAR(50) NOT NULL, -- 'auth', 'monitoring', 'alerts', 'api_limits', 'fraud_detection'
    is_active BOOLEAN DEFAULT true,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

-- =====================================================
-- FONCTIONS UTILITAIRES
-- =====================================================

-- Fonction pour générer des IDs uniques
CREATE OR REPLACE FUNCTION generate_security_id(prefix TEXT)
RETURNS TEXT AS $$
DECLARE
    new_id TEXT;
    year_part TEXT;
    sequence_part TEXT;
BEGIN
    year_part := EXTRACT(YEAR FROM NOW())::TEXT;
    
    LOOP
        sequence_part := LPAD((RANDOM() * 99999)::INTEGER::TEXT, 5, '0');
        new_id := prefix || '-' || year_part || '-' || sequence_part;
        
        -- Vérifier l'unicité selon le préfixe
        IF prefix = 'INC' THEN
            EXIT WHEN NOT EXISTS (SELECT 1 FROM security_incidents WHERE incident_id = new_id);
        ELSIF prefix = 'ALT' THEN
            EXIT WHEN NOT EXISTS (SELECT 1 FROM system_alerts WHERE alert_id = new_id);
        ELSIF prefix = 'AUD' THEN
            EXIT WHEN NOT EXISTS (SELECT 1 FROM security_audits WHERE audit_id = new_id);
        END IF;
    END LOOP;
    
    RETURN new_id;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour calculer le score de menace
CREATE OR REPLACE FUNCTION calculate_threat_score(
    event_type TEXT,
    ip_address INET,
    user_id UUID DEFAULT NULL
) RETURNS INTEGER AS $$
DECLARE
    base_score INTEGER := 0;
    ip_history INTEGER := 0;
    user_history INTEGER := 0;
BEGIN
    -- Score de base selon le type d'événement
    CASE event_type
        WHEN 'failed_login' THEN base_score := 2;
        WHEN 'suspicious_activity' THEN base_score := 5;
        WHEN 'attack_detected' THEN base_score := 8;
        WHEN 'data_breach' THEN base_score := 10;
        ELSE base_score := 1;
    END CASE;
    
    -- Historique de l'IP (dernières 24h)
    SELECT COUNT(*) INTO ip_history
    FROM security_monitoring 
    WHERE ip_address = calculate_threat_score.ip_address 
    AND created_at > NOW() - INTERVAL '24 hours'
    AND threat_level > 3;
    
    -- Historique de l'utilisateur (dernières 24h)
    IF user_id IS NOT NULL THEN
        SELECT COUNT(*) INTO user_history
        FROM security_monitoring 
        WHERE user_id = calculate_threat_score.user_id 
        AND created_at > NOW() - INTERVAL '24 hours'
        AND threat_level > 3;
    END IF;
    
    -- Score final (max 10)
    RETURN LEAST(10, base_score + (ip_history / 2) + (user_history / 3));
END;
$$ LANGUAGE plpgsql;

-- Fonction pour créer une alerte automatique
CREATE OR REPLACE FUNCTION create_security_alert(
    alert_title TEXT,
    alert_message TEXT,
    alert_type TEXT,
    priority TEXT DEFAULT 'medium',
    target_users UUID[] DEFAULT '{}'
) RETURNS UUID AS $$
DECLARE
    alert_id TEXT;
    new_alert_uuid UUID;
BEGIN
    alert_id := generate_security_id('ALT');
    
    INSERT INTO system_alerts (
        alert_id, title, message, alert_type, priority, target_users,
        channels, created_at
    ) VALUES (
        alert_id, alert_title, alert_message, alert_type, priority, target_users,
        ARRAY['dashboard', 'email'], NOW()
    ) RETURNING id INTO new_alert_uuid;
    
    RETURN new_alert_uuid;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- TRIGGERS AUTOMATIQUES
-- =====================================================

-- Trigger pour détecter les tentatives de connexion suspectes
CREATE OR REPLACE FUNCTION detect_suspicious_login()
RETURNS TRIGGER AS $$
DECLARE
    recent_failures INTEGER;
    threat_score INTEGER;
BEGIN
    -- Compter les échecs récents de cette IP
    SELECT COUNT(*) INTO recent_failures
    FROM login_attempts 
    WHERE ip_address = NEW.ip_address 
    AND success = false 
    AND created_at > NOW() - INTERVAL '1 hour';
    
    -- Si plus de 5 échecs en 1h, créer un incident
    IF recent_failures >= 5 THEN
        threat_score := calculate_threat_score('failed_login', NEW.ip_address);
        
        -- Enregistrer l'événement de sécurité
        INSERT INTO security_monitoring (
            event_type, severity_level, source_module, ip_address,
            event_data, threat_level, created_at
        ) VALUES (
            'suspicious_login_attempts',
            CASE WHEN recent_failures > 10 THEN 'critical' ELSE 'warning' END,
            'auth',
            NEW.ip_address,
            jsonb_build_object(
                'failure_count', recent_failures,
                'time_window', '1 hour',
                'last_attempt', NEW.created_at
            ),
            threat_score,
            NOW()
        );
        
        -- Bloquer l'IP si trop de tentatives
        IF recent_failures >= 10 THEN
            INSERT INTO blocked_ips (ip_address, reason, blocked_by, threat_score, expires_at)
            VALUES (
                NEW.ip_address,
                'Automated block: ' || recent_failures || ' failed login attempts',
                'auto_system',
                threat_score,
                NOW() + INTERVAL '24 hours'
            ) ON CONFLICT (ip_address) DO NOTHING;
            
            -- Créer une alerte critique
            PERFORM create_security_alert(
                'IP Address Blocked - Suspicious Activity',
                'IP ' || NEW.ip_address::TEXT || ' has been automatically blocked after ' || recent_failures || ' failed login attempts.',
                'security',
                'high'
            );
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_detect_suspicious_login
    AFTER INSERT ON login_attempts
    FOR EACH ROW
    EXECUTE FUNCTION detect_suspicious_login();

-- =====================================================
-- DONNÉES INITIALES
-- =====================================================

-- Configuration de sécurité par défaut
INSERT INTO security_settings (setting_key, setting_value, description, category) VALUES
('max_login_attempts', '{"value": 5, "time_window_minutes": 60}', 'Nombre maximum de tentatives de connexion par heure', 'auth'),
('session_timeout_minutes', '{"value": 480}', 'Durée de session en minutes (8h)', 'auth'),
('mfa_required_roles', '{"roles": ["pdg", "admin", "syndicate_president"]}', 'Rôles nécessitant une authentification multi-facteurs', 'auth'),
('api_rate_limits', '{"mapbox": 10000, "google_maps": 5000, "stripe": 1000}', 'Limites de taux API par jour', 'api_limits'),
('fraud_detection_threshold', '{"amount": 50000, "frequency": 10}', 'Seuils de détection de fraude', 'fraud_detection'),
('auto_block_enabled', '{"value": true}', 'Blocage automatique des IPs suspectes', 'monitoring'),
('alert_channels', '{"email": true, "push": true, "sms": false}', 'Canaux d\'alerte activés', 'alerts'),
('monitoring_retention_days', '{"value": 90}', 'Durée de rétention des logs de monitoring', 'monitoring')
ON CONFLICT (setting_key) DO NOTHING;

-- Règles de réponse automatique
INSERT INTO automated_responses (trigger_event, condition_rules, action_type, action_config, created_by) VALUES
('failed_login_attempts', 
 '{"threshold": 5, "time_window": "1 hour"}',
 'block_ip',
 '{"duration_hours": 24, "notify_admin": true}',
 NULL),
('api_rate_limit_exceeded',
 '{"threshold": 0.9, "api": "any"}',
 'send_alert',
 '{"priority": "high", "channels": ["email", "dashboard"]}',
 NULL),
('suspicious_transaction',
 '{"amount_threshold": 100000, "frequency_threshold": 5}',
 'send_alert',
 '{"priority": "critical", "channels": ["email", "push", "dashboard"]}',
 NULL);

-- =====================================================
-- POLITIQUES RLS (Row Level Security)
-- =====================================================

-- Activer RLS sur toutes les tables
ALTER TABLE security_monitoring ENABLE ROW LEVEL SECURITY;
ALTER TABLE security_incidents ENABLE ROW LEVEL SECURITY;
ALTER TABLE blocked_ips ENABLE ROW LEVEL SECURITY;
ALTER TABLE login_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE api_monitoring ENABLE ROW LEVEL SECURITY;
ALTER TABLE system_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE automated_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE security_audits ENABLE ROW LEVEL SECURITY;
ALTER TABLE security_settings ENABLE ROW LEVEL SECURITY;

-- Politiques pour les admins/PDG (accès complet)
CREATE POLICY "Admin full access security_monitoring" ON security_monitoring
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM profiles 
            WHERE profiles.id = auth.uid() 
            AND profiles.role IN ('pdg', 'admin')
        )
    );

CREATE POLICY "Admin full access security_incidents" ON security_incidents
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM profiles 
            WHERE profiles.id = auth.uid() 
            AND profiles.role IN ('pdg', 'admin')
        )
    );

CREATE POLICY "Admin full access blocked_ips" ON blocked_ips
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM profiles 
            WHERE profiles.id = auth.uid() 
            AND profiles.role IN ('pdg', 'admin')
        )
    );

CREATE POLICY "Admin full access login_attempts" ON login_attempts
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM profiles 
            WHERE profiles.id = auth.uid() 
            AND profiles.role IN ('pdg', 'admin')
        )
    );

CREATE POLICY "Admin full access api_monitoring" ON api_monitoring
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM profiles 
            WHERE profiles.id = auth.uid() 
            AND profiles.role IN ('pdg', 'admin')
        )
    );

CREATE POLICY "Admin full access system_alerts" ON system_alerts
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM profiles 
            WHERE profiles.id = auth.uid() 
            AND profiles.role IN ('pdg', 'admin')
        )
    );

CREATE POLICY "Admin full access automated_responses" ON automated_responses
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM profiles 
            WHERE profiles.id = auth.uid() 
            AND profiles.role IN ('pdg', 'admin')
        )
    );

CREATE POLICY "Admin full access security_audits" ON security_audits
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM profiles 
            WHERE profiles.id = auth.uid() 
            AND profiles.role IN ('pdg', 'admin')
        )
    );

CREATE POLICY "Admin full access security_settings" ON security_settings
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM profiles 
            WHERE profiles.id = auth.uid() 
            AND profiles.role IN ('pdg', 'admin')
        )
    );

-- =====================================================
-- INDEX POUR PERFORMANCE
-- =====================================================

CREATE INDEX IF NOT EXISTS idx_security_monitoring_created_at ON security_monitoring(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_security_monitoring_event_type ON security_monitoring(event_type);
CREATE INDEX IF NOT EXISTS idx_security_monitoring_severity ON security_monitoring(severity_level);
CREATE INDEX IF NOT EXISTS idx_security_monitoring_ip ON security_monitoring(ip_address);
CREATE INDEX IF NOT EXISTS idx_security_monitoring_user ON security_monitoring(user_id);

CREATE INDEX IF NOT EXISTS idx_login_attempts_ip ON login_attempts(ip_address);
CREATE INDEX IF NOT EXISTS idx_login_attempts_created_at ON login_attempts(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_login_attempts_success ON login_attempts(success);

CREATE INDEX IF NOT EXISTS idx_blocked_ips_ip ON blocked_ips(ip_address);
CREATE INDEX IF NOT EXISTS idx_blocked_ips_expires ON blocked_ips(expires_at);

CREATE INDEX IF NOT EXISTS idx_api_monitoring_created_at ON api_monitoring(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_api_monitoring_provider ON api_monitoring(api_provider);

CREATE INDEX IF NOT EXISTS idx_system_alerts_status ON system_alerts(status);
CREATE INDEX IF NOT EXISTS idx_system_alerts_priority ON system_alerts(priority);
CREATE INDEX IF NOT EXISTS idx_system_alerts_created_at ON system_alerts(created_at DESC);

-- =====================================================
-- COMMENTAIRES
-- =====================================================

COMMENT ON TABLE security_monitoring IS 'Monitoring en temps réel de tous les événements de sécurité';
COMMENT ON TABLE security_incidents IS 'Incidents de sécurité détectés et leur gestion';
COMMENT ON TABLE blocked_ips IS 'Adresses IP bloquées automatiquement ou manuellement';
COMMENT ON TABLE login_attempts IS 'Historique de toutes les tentatives de connexion';
COMMENT ON TABLE api_monitoring IS 'Monitoring des appels API et leur performance';
COMMENT ON TABLE system_alerts IS 'Alertes système pour le PDG et les admins';
COMMENT ON TABLE automated_responses IS 'Configuration des réponses automatiques aux menaces';
COMMENT ON TABLE security_audits IS 'Audit complet de toutes les actions utilisateurs';
COMMENT ON TABLE security_settings IS 'Configuration du système de sécurité';
