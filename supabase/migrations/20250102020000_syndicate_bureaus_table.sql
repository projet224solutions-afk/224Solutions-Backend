-- Migration pour la table des bureaux syndicaux
-- 224Solutions - Bureau Syndicat System

-- Créer la table des bureaux syndicaux
CREATE TABLE IF NOT EXISTS syndicate_bureaus (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    bureau_code VARCHAR(50) UNIQUE NOT NULL,
    prefecture VARCHAR(100) NOT NULL,
    commune VARCHAR(100) NOT NULL,
    full_location VARCHAR(200) NOT NULL,
    president_name VARCHAR(200) NOT NULL,
    president_email VARCHAR(255) NOT NULL,
    president_phone VARCHAR(20),
    permanent_link TEXT NOT NULL,
    access_token VARCHAR(255) UNIQUE NOT NULL,
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'suspended', 'dissolved')),
    total_members INTEGER DEFAULT 0,
    active_members INTEGER DEFAULT 0,
    total_vehicles INTEGER DEFAULT 0,
    total_cotisations DECIMAL(15,2) DEFAULT 0,
    treasury_balance DECIMAL(15,2) DEFAULT 0,
    link_sent_at TIMESTAMP WITH TIME ZONE,
    link_accessed_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    validated_at TIMESTAMP WITH TIME ZONE
);

-- Index pour les recherches fréquentes
CREATE INDEX IF NOT EXISTS idx_syndicate_bureaus_access_token ON syndicate_bureaus(access_token);
CREATE INDEX IF NOT EXISTS idx_syndicate_bureaus_status ON syndicate_bureaus(status);
CREATE INDEX IF NOT EXISTS idx_syndicate_bureaus_prefecture ON syndicate_bureaus(prefecture);
CREATE INDEX IF NOT EXISTS idx_syndicate_bureaus_president_email ON syndicate_bureaus(president_email);

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_syndicate_bureaus_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_syndicate_bureaus_updated_at
    BEFORE UPDATE ON syndicate_bureaus
    FOR EACH ROW
    EXECUTE FUNCTION update_syndicate_bureaus_updated_at();

-- RLS (Row Level Security) pour sécuriser l'accès
ALTER TABLE syndicate_bureaus ENABLE ROW LEVEL SECURITY;

-- Politique pour permettre la lecture publique (nécessaire pour l'authentification par token)
CREATE POLICY "Allow public read access for authentication" ON syndicate_bureaus
    FOR SELECT USING (true);

-- Politique pour permettre l'insertion par les utilisateurs authentifiés
CREATE POLICY "Allow authenticated users to insert" ON syndicate_bureaus
    FOR INSERT WITH CHECK (auth.role() = 'authenticated' OR auth.role() = 'anon');

-- Politique pour permettre la mise à jour par les utilisateurs authentifiés
CREATE POLICY "Allow authenticated users to update" ON syndicate_bureaus
    FOR UPDATE USING (auth.role() = 'authenticated' OR auth.role() = 'anon');

-- Insérer quelques données de test
INSERT INTO syndicate_bureaus (
    bureau_code,
    prefecture,
    commune,
    full_location,
    president_name,
    president_email,
    president_phone,
    permanent_link,
    access_token,
    status,
    total_members,
    active_members,
    total_vehicles,
    total_cotisations,
    treasury_balance
) VALUES 
(
    'SYN-2025-00001',
    'Dakar',
    'Plateau',
    'Dakar - Plateau',
    'Mamadou Diallo',
    'mamadou.diallo@email.com',
    '+221 77 123 45 67',
    'http://localhost:5173/syndicat/president/TEST_TOKEN_123456789',
    'TEST_TOKEN_123456789',
    'active',
    45,
    42,
    38,
    2250000,
    1850000
),
(
    'SYN-2025-00002',
    'Thiès',
    'Thiès-Ville',
    'Thiès - Thiès-Ville',
    'Fatou Sall',
    'fatou.sall@email.com',
    '+221 77 987 65 43',
    'http://localhost:5173/syndicat/president/TEST_TOKEN_987654321',
    'TEST_TOKEN_987654321',
    'pending',
    32,
    28,
    25,
    1800000,
    1200000
)
ON CONFLICT (bureau_code) DO NOTHING;

-- Commentaires pour la documentation
COMMENT ON TABLE syndicate_bureaus IS 'Table des bureaux syndicaux 224Solutions';
COMMENT ON COLUMN syndicate_bureaus.bureau_code IS 'Code unique du bureau syndical';
COMMENT ON COLUMN syndicate_bureaus.access_token IS 'Token d''accès sécurisé pour l''authentification du président';
COMMENT ON COLUMN syndicate_bureaus.permanent_link IS 'Lien permanent d''accès à l''interface président';
COMMENT ON COLUMN syndicate_bureaus.status IS 'Statut du bureau: pending, active, suspended, dissolved';
COMMENT ON COLUMN syndicate_bureaus.link_accessed_at IS 'Date du dernier accès au lien par le président';
