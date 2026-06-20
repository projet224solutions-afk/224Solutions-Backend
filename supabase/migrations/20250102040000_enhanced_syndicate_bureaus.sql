-- Migration pour améliorer la table des bureaux syndicaux
-- Ajout de nouvelles colonnes pour les fonctionnalités avancées

-- Ajouter les nouvelles colonnes à la table syndicate_bureaus
ALTER TABLE syndicate_bureaus 
ADD COLUMN IF NOT EXISTS email_sent_count INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS sms_sent_count INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS is_link_permanent BOOLEAN DEFAULT true,
ADD COLUMN IF NOT EXISTS qr_code TEXT,
ADD COLUMN IF NOT EXISTS download_count INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS mobile_access_count INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS desktop_access_count INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS tablet_access_count INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS last_activity TIMESTAMP WITH TIME ZONE DEFAULT NOW();

-- Créer une table pour les membres des bureaux syndicaux
CREATE TABLE IF NOT EXISTS syndicate_members (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    bureau_id UUID REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL,
    phone VARCHAR(20),
    license_number VARCHAR(50),
    vehicle_type VARCHAR(50),
    vehicle_serial VARCHAR(50),
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'suspended')),
    cotisation_status VARCHAR(20) DEFAULT 'pending' CHECK (cotisation_status IN ('paid', 'pending', 'overdue')),
    join_date DATE DEFAULT CURRENT_DATE,
    last_cotisation_date DATE,
    total_cotisations INTEGER DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Créer une table pour les véhicules
CREATE TABLE IF NOT EXISTS syndicate_vehicles (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    bureau_id UUID REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    member_id UUID REFERENCES syndicate_members(id) ON DELETE CASCADE,
    serial_number VARCHAR(50) UNIQUE NOT NULL,
    type VARCHAR(50) NOT NULL,
    brand VARCHAR(50),
    model VARCHAR(50),
    year INTEGER,
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'maintenance', 'retired')),
    insurance_expiry DATE,
    last_inspection DATE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Créer une table pour les transactions financières
CREATE TABLE IF NOT EXISTS syndicate_transactions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    bureau_id UUID REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    member_id UUID REFERENCES syndicate_members(id) ON DELETE SET NULL,
    type VARCHAR(20) NOT NULL CHECK (type IN ('cotisation', 'fine', 'bonus', 'expense')),
    amount INTEGER NOT NULL,
    description TEXT NOT NULL,
    status VARCHAR(20) DEFAULT 'completed' CHECK (status IN ('completed', 'pending', 'cancelled')),
    receipt_url TEXT,
    transaction_date DATE DEFAULT CURRENT_DATE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Créer une table pour les alertes SOS
CREATE TABLE IF NOT EXISTS syndicate_sos_alerts (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    bureau_id UUID REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    member_id UUID REFERENCES syndicate_members(id) ON DELETE CASCADE,
    alert_type VARCHAR(20) NOT NULL CHECK (alert_type IN ('emergency', 'breakdown', 'accident', 'theft')),
    severity VARCHAR(20) NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
    latitude DECIMAL(10, 8),
    longitude DECIMAL(11, 8),
    address TEXT,
    description TEXT NOT NULL,
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'resolved', 'false_alarm')),
    resolved_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Créer des index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_syndicate_members_bureau_id ON syndicate_members(bureau_id);
CREATE INDEX IF NOT EXISTS idx_syndicate_members_status ON syndicate_members(status);
CREATE INDEX IF NOT EXISTS idx_syndicate_vehicles_bureau_id ON syndicate_vehicles(bureau_id);
CREATE INDEX IF NOT EXISTS idx_syndicate_vehicles_member_id ON syndicate_vehicles(member_id);
CREATE INDEX IF NOT EXISTS idx_syndicate_transactions_bureau_id ON syndicate_transactions(bureau_id);
CREATE INDEX IF NOT EXISTS idx_syndicate_transactions_member_id ON syndicate_transactions(member_id);
CREATE INDEX IF NOT EXISTS idx_syndicate_sos_alerts_bureau_id ON syndicate_sos_alerts(bureau_id);
CREATE INDEX IF NOT EXISTS idx_syndicate_sos_alerts_status ON syndicate_sos_alerts(status);

-- Fonction pour mettre à jour automatiquement les statistiques du bureau
CREATE OR REPLACE FUNCTION update_bureau_statistics()
RETURNS TRIGGER AS $$
BEGIN
    -- Mettre à jour les statistiques du bureau
    UPDATE syndicate_bureaus 
    SET 
        total_members = (
            SELECT COUNT(*) 
            FROM syndicate_members 
            WHERE bureau_id = COALESCE(NEW.bureau_id, OLD.bureau_id)
        ),
        active_members = (
            SELECT COUNT(*) 
            FROM syndicate_members 
            WHERE bureau_id = COALESCE(NEW.bureau_id, OLD.bureau_id) 
            AND status = 'active'
        ),
        total_vehicles = (
            SELECT COUNT(*) 
            FROM syndicate_vehicles 
            WHERE bureau_id = COALESCE(NEW.bureau_id, OLD.bureau_id)
        ),
        total_cotisations = (
            SELECT COALESCE(SUM(amount), 0) 
            FROM syndicate_transactions 
            WHERE bureau_id = COALESCE(NEW.bureau_id, OLD.bureau_id) 
            AND type = 'cotisation' 
            AND status = 'completed'
        ),
        updated_at = NOW()
    WHERE id = COALESCE(NEW.bureau_id, OLD.bureau_id);
    
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Créer les triggers pour la mise à jour automatique des statistiques
DROP TRIGGER IF EXISTS trigger_update_bureau_stats_members ON syndicate_members;
CREATE TRIGGER trigger_update_bureau_stats_members
    AFTER INSERT OR UPDATE OR DELETE ON syndicate_members
    FOR EACH ROW EXECUTE FUNCTION update_bureau_statistics();

DROP TRIGGER IF EXISTS trigger_update_bureau_stats_vehicles ON syndicate_vehicles;
CREATE TRIGGER trigger_update_bureau_stats_vehicles
    AFTER INSERT OR UPDATE OR DELETE ON syndicate_vehicles
    FOR EACH ROW EXECUTE FUNCTION update_bureau_statistics();

DROP TRIGGER IF EXISTS trigger_update_bureau_stats_transactions ON syndicate_transactions;
CREATE TRIGGER trigger_update_bureau_stats_transactions
    AFTER INSERT OR UPDATE OR DELETE ON syndicate_transactions
    FOR EACH ROW EXECUTE FUNCTION update_bureau_statistics();

-- Fonction pour générer un QR Code (simulation)
CREATE OR REPLACE FUNCTION generate_qr_code(link TEXT)
RETURNS TEXT AS $$
BEGIN
    -- En production, ceci devrait appeler une vraie API de génération de QR Code
    RETURN 'data:image/svg+xml;base64,' || encode(
        ('<svg width="200" height="200" xmlns="http://www.w3.org/2000/svg">' ||
         '<rect width="200" height="200" fill="white"/>' ||
         '<text x="100" y="100" text-anchor="middle" font-size="10">' ||
         'QR Code: ' || substring(link, 1, 20) || '...' ||
         '</text></svg>')::bytea, 'base64'
    );
END;
$$ LANGUAGE plpgsql;

-- Fonction pour mettre à jour automatiquement le QR Code lors de la création d'un bureau
CREATE OR REPLACE FUNCTION update_bureau_qr_code()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.permanent_link IS NOT NULL AND (OLD.permanent_link IS NULL OR OLD.permanent_link != NEW.permanent_link) THEN
        NEW.qr_code = generate_qr_code(NEW.permanent_link);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Créer le trigger pour la génération automatique du QR Code
DROP TRIGGER IF EXISTS trigger_generate_qr_code ON syndicate_bureaus;
CREATE TRIGGER trigger_generate_qr_code
    BEFORE INSERT OR UPDATE ON syndicate_bureaus
    FOR EACH ROW EXECUTE FUNCTION update_bureau_qr_code();

-- Activer RLS (Row Level Security) sur toutes les nouvelles tables
ALTER TABLE syndicate_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE syndicate_vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE syndicate_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE syndicate_sos_alerts ENABLE ROW LEVEL SECURITY;

-- Politiques RLS pour les membres
CREATE POLICY "Membres visibles par le bureau" ON syndicate_members
    FOR ALL USING (
        bureau_id IN (
            SELECT id FROM syndicate_bureaus 
            WHERE access_token = current_setting('request.jwt.claims', true)::json->>'access_token'
        )
    );

-- Politiques RLS pour les véhicules
CREATE POLICY "Véhicules visibles par le bureau" ON syndicate_vehicles
    FOR ALL USING (
        bureau_id IN (
            SELECT id FROM syndicate_bureaus 
            WHERE access_token = current_setting('request.jwt.claims', true)::json->>'access_token'
        )
    );

-- Politiques RLS pour les transactions
CREATE POLICY "Transactions visibles par le bureau" ON syndicate_transactions
    FOR ALL USING (
        bureau_id IN (
            SELECT id FROM syndicate_bureaus 
            WHERE access_token = current_setting('request.jwt.claims', true)::json->>'access_token'
        )
    );

-- Politiques RLS pour les alertes SOS
CREATE POLICY "Alertes SOS visibles par le bureau" ON syndicate_sos_alerts
    FOR ALL USING (
        bureau_id IN (
            SELECT id FROM syndicate_bureaus 
            WHERE access_token = current_setting('request.jwt.claims', true)::json->>'access_token'
        )
    );

-- Insérer des données de test si aucun bureau n'existe
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM syndicate_bureaus LIMIT 1) THEN
        -- Insérer un bureau de test
        INSERT INTO syndicate_bureaus (
            bureau_code, prefecture, commune, full_location,
            president_name, president_email, president_phone,
            permanent_link, access_token, status,
            total_members, active_members, total_vehicles, total_cotisations,
            email_sent_count, sms_sent_count, is_link_permanent
        ) VALUES (
            'SYN-2025-00001', 'Dakar', 'Plateau', 'Dakar - Plateau',
            'Mamadou Diallo', 'mamadou.diallo@email.com', '+221 77 123 45 67',
            'https://224solution.net/syndicat/president/abc123def456789',
            'abc123def456789', 'active',
            45, 42, 38, 2250000,
            3, 1, true
        );
        
        RAISE NOTICE 'Bureau de test créé avec succès';
    END IF;
END $$;

-- Commentaires sur les tables
COMMENT ON TABLE syndicate_members IS 'Membres des bureaux syndicaux';
COMMENT ON TABLE syndicate_vehicles IS 'Véhicules enregistrés dans les bureaux syndicaux';
COMMENT ON TABLE syndicate_transactions IS 'Transactions financières des bureaux syndicaux';
COMMENT ON TABLE syndicate_sos_alerts IS 'Alertes SOS émises par les membres';

COMMENT ON COLUMN syndicate_bureaus.email_sent_count IS 'Nombre d''emails envoyés au président';
COMMENT ON COLUMN syndicate_bureaus.sms_sent_count IS 'Nombre de SMS envoyés au président';
COMMENT ON COLUMN syndicate_bureaus.is_link_permanent IS 'Indique si le lien d''accès est permanent';
COMMENT ON COLUMN syndicate_bureaus.qr_code IS 'QR Code pour accès rapide (base64)';
COMMENT ON COLUMN syndicate_bureaus.download_count IS 'Nombre de téléchargements de l''interface';
COMMENT ON COLUMN syndicate_bureaus.mobile_access_count IS 'Nombre d''accès depuis mobile';
COMMENT ON COLUMN syndicate_bureaus.desktop_access_count IS 'Nombre d''accès depuis PC';
COMMENT ON COLUMN syndicate_bureaus.tablet_access_count IS 'Nombre d''accès depuis tablette';
COMMENT ON COLUMN syndicate_bureaus.last_activity IS 'Dernière activité du bureau';

-- Afficher un résumé de la migration
DO $$
BEGIN
    RAISE NOTICE '=== MIGRATION TERMINÉE AVEC SUCCÈS ===';
    RAISE NOTICE 'Tables créées/mises à jour:';
    RAISE NOTICE '- syndicate_bureaus (améliorée)';
    RAISE NOTICE '- syndicate_members (nouvelle)';
    RAISE NOTICE '- syndicate_vehicles (nouvelle)';
    RAISE NOTICE '- syndicate_transactions (nouvelle)';
    RAISE NOTICE '- syndicate_sos_alerts (nouvelle)';
    RAISE NOTICE 'Fonctionnalités ajoutées:';
    RAISE NOTICE '- Statistiques automatiques';
    RAISE NOTICE '- QR Code automatique';
    RAISE NOTICE '- Sécurité RLS complète';
    RAISE NOTICE '- Triggers de mise à jour';
    RAISE NOTICE '- Index de performance';
END $$;

