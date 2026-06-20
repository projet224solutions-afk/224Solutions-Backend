-- ===================================================
-- MIGRATION: Système de transactions wallet 224SOLUTIONS
-- Date: 2024-12-01
-- Description: Système complet de gestion des wallets, transactions, commissions et revenus
-- ===================================================

-- 1. Table des wallets utilisateurs
CREATE TABLE IF NOT EXISTS wallets (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
    balance DECIMAL(15,2) DEFAULT 0.00 CHECK (balance >= 0),
    currency VARCHAR(3) DEFAULT 'XAF',
    pin_hash VARCHAR(255), -- Hash du PIN pour sécurité
    biometric_enabled BOOLEAN DEFAULT false,
    status wallet_status DEFAULT 'active',
    daily_limit DECIMAL(15,2) DEFAULT 1000000.00, -- Limite quotidienne
    monthly_limit DECIMAL(15,2) DEFAULT 10000000.00, -- Limite mensuelle
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id)
);

-- Type enum pour le statut des wallets
CREATE TYPE wallet_status AS ENUM ('active', 'suspended', 'blocked', 'pending_verification');

-- 2. Table des transactions
CREATE TABLE IF NOT EXISTS wallet_transactions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    transaction_id VARCHAR(50) UNIQUE NOT NULL, -- ID unique lisible
    sender_wallet_id UUID REFERENCES wallets(id),
    receiver_wallet_id UUID REFERENCES wallets(id),
    amount DECIMAL(15,2) NOT NULL CHECK (amount > 0),
    fee DECIMAL(15,2) DEFAULT 0.00,
    net_amount DECIMAL(15,2) NOT NULL, -- Montant après commission
    currency VARCHAR(3) DEFAULT 'XAF',
    transaction_type transaction_type NOT NULL,
    status transaction_status DEFAULT 'pending',
    description TEXT,
    reference_id VARCHAR(100), -- Référence externe (Mobile Money, etc.)
    api_service VARCHAR(50), -- Service utilisé (orange_money, mtn_momo, etc.)
    fraud_score INTEGER DEFAULT 0 CHECK (fraud_score >= 0 AND fraud_score <= 100),
    ip_address INET,
    device_info JSONB,
    location_data JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE,
    
    -- Contraintes de cohérence
    CONSTRAINT different_wallets CHECK (sender_wallet_id != receiver_wallet_id OR sender_wallet_id IS NULL OR receiver_wallet_id IS NULL),
    CONSTRAINT valid_net_amount CHECK (net_amount = amount - fee)
);

-- Types enum pour les transactions
CREATE TYPE transaction_type AS ENUM (
    'transfer', 'deposit', 'withdrawal', 'payment', 'refund', 
    'commission', 'mobile_money_in', 'mobile_money_out', 
    'card_payment', 'bank_transfer'
);

CREATE TYPE transaction_status AS ENUM (
    'pending', 'processing', 'completed', 'failed', 
    'cancelled', 'refunded', 'disputed'
);

-- 3. Table de configuration des commissions
CREATE TABLE IF NOT EXISTS commission_config (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    service_name VARCHAR(50) NOT NULL, -- orange_money, mtn_momo, visa, mastercard, etc.
    transaction_type transaction_type NOT NULL,
    commission_type commission_type DEFAULT 'percentage',
    commission_value DECIMAL(10,4) NOT NULL CHECK (commission_value >= 0),
    min_commission DECIMAL(15,2) DEFAULT 0.00,
    max_commission DECIMAL(15,2),
    min_amount DECIMAL(15,2) DEFAULT 0.00, -- Montant minimum pour appliquer cette commission
    max_amount DECIMAL(15,2), -- Montant maximum pour cette commission
    is_active BOOLEAN DEFAULT true,
    effective_from TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    effective_until TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(service_name, transaction_type, effective_from)
);

-- Type enum pour les commissions
CREATE TYPE commission_type AS ENUM ('percentage', 'fixed', 'tiered');

-- 4. Table des commissions collectées
CREATE TABLE IF NOT EXISTS collected_commissions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    transaction_id UUID REFERENCES wallet_transactions(id) ON DELETE CASCADE,
    service_name VARCHAR(50) NOT NULL,
    commission_amount DECIMAL(15,2) NOT NULL CHECK (commission_amount >= 0),
    commission_rate DECIMAL(10,4) NOT NULL,
    commission_type commission_type NOT NULL,
    collected_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Index pour les rapports
    INDEX idx_commissions_service_date ON collected_commissions(service_name, collected_at),
    INDEX idx_commissions_date ON collected_commissions(collected_at)
);

-- 5. Table de détection anti-fraude
CREATE TABLE IF NOT EXISTS fraud_detection_logs (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    transaction_id UUID REFERENCES wallet_transactions(id) ON DELETE CASCADE,
    user_id UUID REFERENCES profiles(id),
    rule_triggered VARCHAR(100) NOT NULL,
    risk_level risk_level DEFAULT 'low',
    score INTEGER CHECK (score >= 0 AND score <= 100),
    details JSONB,
    action_taken fraud_action DEFAULT 'allow',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Types enum pour la fraude
CREATE TYPE risk_level AS ENUM ('low', 'medium', 'high', 'critical');
CREATE TYPE fraud_action AS ENUM ('allow', 'review', 'block', 'require_verification');

-- 6. Table des revenus journaliers (pour les rapports)
CREATE TABLE IF NOT EXISTS daily_revenue_summary (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    date DATE NOT NULL,
    total_transactions INTEGER DEFAULT 0,
    total_volume DECIMAL(15,2) DEFAULT 0.00,
    total_commissions DECIMAL(15,2) DEFAULT 0.00,
    avg_transaction_amount DECIMAL(15,2) DEFAULT 0.00,
    top_service VARCHAR(50),
    top_service_volume DECIMAL(15,2) DEFAULT 0.00,
    fraud_blocked_count INTEGER DEFAULT 0,
    fraud_blocked_amount DECIMAL(15,2) DEFAULT 0.00,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(date)
);

-- 7. Table des alertes automatiques
CREATE TABLE IF NOT EXISTS revenue_alerts (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    alert_type alert_type NOT NULL,
    severity alert_severity DEFAULT 'info',
    title VARCHAR(200) NOT NULL,
    message TEXT NOT NULL,
    details JSONB,
    is_read BOOLEAN DEFAULT false,
    is_resolved BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    resolved_at TIMESTAMP WITH TIME ZONE,
    resolved_by UUID REFERENCES profiles(id)
);

-- Types enum pour les alertes
CREATE TYPE alert_type AS ENUM (
    'high_volume', 'unusual_pattern', 'fraud_spike', 'revenue_drop',
    'commission_anomaly', 'system_error', 'threshold_exceeded'
);

CREATE TYPE alert_severity AS ENUM ('info', 'warning', 'error', 'critical');

-- ===================================================
-- FONCTIONS UTILITAIRES
-- ===================================================

-- Fonction pour générer un ID de transaction unique
CREATE OR REPLACE FUNCTION generate_transaction_id()
RETURNS VARCHAR(50) AS $$
DECLARE
    new_id VARCHAR(50);
    counter INTEGER := 0;
BEGIN
    LOOP
        new_id := '224TXN' || TO_CHAR(NOW(), 'YYYYMMDD') || 
                  LPAD(EXTRACT(EPOCH FROM NOW())::BIGINT % 1000000, 6, '0') ||
                  LPAD(counter, 3, '0');
        
        EXIT WHEN NOT EXISTS (SELECT 1 FROM wallet_transactions WHERE transaction_id = new_id);
        
        counter := counter + 1;
        IF counter > 999 THEN
            RAISE EXCEPTION 'Impossible de générer un ID de transaction unique';
        END IF;
    END LOOP;
    
    RETURN new_id;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour calculer la commission
CREATE OR REPLACE FUNCTION calculate_commission(
    p_service_name VARCHAR(50),
    p_transaction_type transaction_type,
    p_amount DECIMAL(15,2)
)
RETURNS DECIMAL(15,2) AS $$
DECLARE
    config RECORD;
    commission DECIMAL(15,2) := 0.00;
BEGIN
    -- Récupérer la configuration de commission active
    SELECT * INTO config
    FROM commission_config
    WHERE service_name = p_service_name
    AND transaction_type = p_transaction_type
    AND is_active = true
    AND (effective_until IS NULL OR effective_until > NOW())
    AND p_amount >= COALESCE(min_amount, 0)
    AND (max_amount IS NULL OR p_amount <= max_amount)
    ORDER BY effective_from DESC
    LIMIT 1;
    
    IF NOT FOUND THEN
        RETURN 0.00; -- Pas de commission configurée
    END IF;
    
    -- Calculer la commission selon le type
    CASE config.commission_type
        WHEN 'percentage' THEN
            commission := p_amount * (config.commission_value / 100);
        WHEN 'fixed' THEN
            commission := config.commission_value;
        WHEN 'tiered' THEN
            -- Pour les commissions à paliers, utiliser le pourcentage pour l'instant
            commission := p_amount * (config.commission_value / 100);
    END CASE;
    
    -- Appliquer les limites min/max
    IF config.min_commission IS NOT NULL THEN
        commission := GREATEST(commission, config.min_commission);
    END IF;
    
    IF config.max_commission IS NOT NULL THEN
        commission := LEAST(commission, config.max_commission);
    END IF;
    
    RETURN commission;
END;
$$ LANGUAGE plpgsql;

-- Fonction de détection anti-fraude
CREATE OR REPLACE FUNCTION detect_fraud(
    p_user_id UUID,
    p_amount DECIMAL(15,2),
    p_transaction_type transaction_type,
    p_ip_address INET DEFAULT NULL,
    p_device_info JSONB DEFAULT NULL
)
RETURNS INTEGER AS $$
DECLARE
    fraud_score INTEGER := 0;
    daily_count INTEGER;
    daily_amount DECIMAL(15,2);
    hourly_count INTEGER;
    avg_amount DECIMAL(15,2);
    recent_locations INTEGER;
BEGIN
    -- 1. Vérifier le nombre de transactions dans les dernières 24h
    SELECT COUNT(*), COALESCE(SUM(amount), 0)
    INTO daily_count, daily_amount
    FROM wallet_transactions wt
    JOIN wallets w ON (wt.sender_wallet_id = w.id OR wt.receiver_wallet_id = w.id)
    WHERE w.user_id = p_user_id
    AND wt.created_at > NOW() - INTERVAL '24 hours'
    AND wt.status IN ('completed', 'processing');
    
    -- Score basé sur le volume quotidien
    IF daily_count > 50 THEN fraud_score := fraud_score + 30;
    ELSIF daily_count > 20 THEN fraud_score := fraud_score + 15;
    ELSIF daily_count > 10 THEN fraud_score := fraud_score + 5;
    END IF;
    
    -- Score basé sur le montant quotidien
    IF daily_amount > 10000000 THEN fraud_score := fraud_score + 40; -- > 10M XAF
    ELSIF daily_amount > 5000000 THEN fraud_score := fraud_score + 20; -- > 5M XAF
    ELSIF daily_amount > 1000000 THEN fraud_score := fraud_score + 10; -- > 1M XAF
    END IF;
    
    -- 2. Vérifier la fréquence horaire
    SELECT COUNT(*)
    INTO hourly_count
    FROM wallet_transactions wt
    JOIN wallets w ON (wt.sender_wallet_id = w.id OR wt.receiver_wallet_id = w.id)
    WHERE w.user_id = p_user_id
    AND wt.created_at > NOW() - INTERVAL '1 hour'
    AND wt.status IN ('completed', 'processing');
    
    IF hourly_count > 10 THEN fraud_score := fraud_score + 25;
    ELSIF hourly_count > 5 THEN fraud_score := fraud_score + 10;
    END IF;
    
    -- 3. Comparer avec le montant moyen de l'utilisateur
    SELECT AVG(amount)
    INTO avg_amount
    FROM wallet_transactions wt
    JOIN wallets w ON (wt.sender_wallet_id = w.id OR wt.receiver_wallet_id = w.id)
    WHERE w.user_id = p_user_id
    AND wt.created_at > NOW() - INTERVAL '30 days'
    AND wt.status = 'completed';
    
    IF avg_amount IS NOT NULL AND p_amount > (avg_amount * 10) THEN
        fraud_score := fraud_score + 30; -- Montant 10x supérieur à la moyenne
    ELSIF avg_amount IS NOT NULL AND p_amount > (avg_amount * 5) THEN
        fraud_score := fraud_score + 15; -- Montant 5x supérieur à la moyenne
    END IF;
    
    -- 4. Vérifier les localisations multiples (si disponible)
    IF p_ip_address IS NOT NULL THEN
        SELECT COUNT(DISTINCT ip_address)
        INTO recent_locations
        FROM wallet_transactions wt
        JOIN wallets w ON (wt.sender_wallet_id = w.id OR wt.receiver_wallet_id = w.id)
        WHERE w.user_id = p_user_id
        AND wt.created_at > NOW() - INTERVAL '1 hour'
        AND wt.ip_address IS NOT NULL;
        
        IF recent_locations > 3 THEN fraud_score := fraud_score + 20;
        ELSIF recent_locations > 1 THEN fraud_score := fraud_score + 10;
        END IF;
    END IF;
    
    -- Limiter le score à 100
    RETURN LEAST(fraud_score, 100);
END;
$$ LANGUAGE plpgsql;

-- ===================================================
-- TRIGGERS ET AUTOMATISATIONS
-- ===================================================

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Appliquer le trigger sur toutes les tables pertinentes
CREATE TRIGGER update_wallets_updated_at
    BEFORE UPDATE ON wallets
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_transactions_updated_at
    BEFORE UPDATE ON wallet_transactions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_commission_config_updated_at
    BEFORE UPDATE ON commission_config
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_daily_revenue_updated_at
    BEFORE UPDATE ON daily_revenue_summary
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Trigger pour automatiser la création des commissions
CREATE OR REPLACE FUNCTION auto_create_commission()
RETURNS TRIGGER AS $$
DECLARE
    commission_amount DECIMAL(15,2);
BEGIN
    -- Calculer la commission seulement pour les transactions complétées
    IF NEW.status = 'completed' AND NEW.fee > 0 THEN
        INSERT INTO collected_commissions (
            transaction_id,
            service_name,
            commission_amount,
            commission_rate,
            commission_type
        )
        SELECT 
            NEW.id,
            COALESCE(NEW.api_service, 'internal'),
            NEW.fee,
            cc.commission_value,
            cc.commission_type
        FROM commission_config cc
        WHERE cc.service_name = COALESCE(NEW.api_service, 'internal')
        AND cc.transaction_type = NEW.transaction_type
        AND cc.is_active = true
        AND (cc.effective_until IS NULL OR cc.effective_until > NOW())
        ORDER BY cc.effective_from DESC
        LIMIT 1;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER auto_commission_trigger
    AFTER INSERT OR UPDATE ON wallet_transactions
    FOR EACH ROW EXECUTE FUNCTION auto_create_commission();

-- ===================================================
-- INDEXES POUR PERFORMANCE
-- ===================================================

-- Index pour les wallets
CREATE INDEX IF NOT EXISTS idx_wallets_user_id ON wallets(user_id);
CREATE INDEX IF NOT EXISTS idx_wallets_status ON wallets(status);

-- Index pour les transactions
CREATE INDEX IF NOT EXISTS idx_transactions_sender ON wallet_transactions(sender_wallet_id);
CREATE INDEX IF NOT EXISTS idx_transactions_receiver ON wallet_transactions(receiver_wallet_id);
CREATE INDEX IF NOT EXISTS idx_transactions_status ON wallet_transactions(status);
CREATE INDEX IF NOT EXISTS idx_transactions_type ON wallet_transactions(transaction_type);
CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON wallet_transactions(created_at);
CREATE INDEX IF NOT EXISTS idx_transactions_api_service ON wallet_transactions(api_service);
CREATE INDEX IF NOT EXISTS idx_transactions_fraud_score ON wallet_transactions(fraud_score);

-- Index composites pour les requêtes courantes
CREATE INDEX IF NOT EXISTS idx_transactions_status_date ON wallet_transactions(status, created_at);
CREATE INDEX IF NOT EXISTS idx_transactions_service_date ON wallet_transactions(api_service, created_at);

-- Index pour la configuration des commissions
CREATE INDEX IF NOT EXISTS idx_commission_config_service_type ON commission_config(service_name, transaction_type);
CREATE INDEX IF NOT EXISTS idx_commission_config_active ON commission_config(is_active, effective_from);

-- Index pour les logs de fraude
CREATE INDEX IF NOT EXISTS idx_fraud_logs_user ON fraud_detection_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_fraud_logs_risk ON fraud_detection_logs(risk_level);
CREATE INDEX IF NOT EXISTS idx_fraud_logs_date ON fraud_detection_logs(created_at);

-- Index pour les alertes
CREATE INDEX IF NOT EXISTS idx_alerts_type ON revenue_alerts(alert_type);
CREATE INDEX IF NOT EXISTS idx_alerts_unread ON revenue_alerts(is_read) WHERE is_read = false;
CREATE INDEX IF NOT EXISTS idx_alerts_date ON revenue_alerts(created_at);

-- ===================================================
-- TABLE CARTES VIRTUELLES
-- ===================================================

-- Table des cartes virtuelles pour chaque utilisateur
CREATE TABLE IF NOT EXISTS virtual_cards (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
    wallet_id UUID REFERENCES wallets(id) ON DELETE CASCADE,
    card_number VARCHAR(16) UNIQUE NOT NULL,
    card_holder_name VARCHAR(100) NOT NULL,
    expiry_month VARCHAR(2) NOT NULL,
    expiry_year VARCHAR(4) NOT NULL,
    cvv VARCHAR(3) NOT NULL,
    card_type card_type DEFAULT 'virtual',
    card_status card_status DEFAULT 'active',
    daily_limit DECIMAL(15,2) DEFAULT 500000.00,
    monthly_limit DECIMAL(15,2) DEFAULT 5000000.00,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id)
);

-- Types enum pour les cartes
CREATE TYPE card_type AS ENUM ('virtual', 'physical', 'prepaid');
CREATE TYPE card_status AS ENUM ('active', 'blocked', 'expired', 'pending');

-- ===================================================
-- FONCTIONS DE GÉNÉRATION AUTOMATIQUE
-- ===================================================

-- Fonction pour générer un numéro de carte virtuelle
CREATE OR REPLACE FUNCTION generate_virtual_card_number()
RETURNS VARCHAR(16) AS $$
DECLARE
    new_card_number VARCHAR(16);
    counter INTEGER := 0;
BEGIN
    LOOP
        -- Générer un numéro commençant par 2245 (224Solutions + 5 pour virtuel)
        new_card_number := '2245' || LPAD(EXTRACT(EPOCH FROM NOW())::BIGINT % 1000000000000, 12, '0');
        
        EXIT WHEN NOT EXISTS (SELECT 1 FROM virtual_cards WHERE card_number = new_card_number);
        
        counter := counter + 1;
        IF counter > 999 THEN
            RAISE EXCEPTION 'Impossible de générer un numéro de carte unique';
        END IF;
    END LOOP;
    
    RETURN new_card_number;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour générer un CVV
CREATE OR REPLACE FUNCTION generate_cvv()
RETURNS VARCHAR(3) AS $$
BEGIN
    RETURN LPAD((RANDOM() * 999)::INTEGER, 3, '0');
END;
$$ LANGUAGE plpgsql;

-- Fonction déclenchée lors de la création d'un profil utilisateur
CREATE OR REPLACE FUNCTION create_user_wallet_and_card()
RETURNS TRIGGER AS $$
DECLARE
    new_wallet_id UUID;
    card_number VARCHAR(16);
    cvv VARCHAR(3);
    expiry_year VARCHAR(4);
    expiry_month VARCHAR(2);
BEGIN
    -- Créer le wallet automatiquement
    INSERT INTO wallets (user_id, balance, currency, status)
    VALUES (NEW.id, 0.00, 'XAF', 'active')
    RETURNING id INTO new_wallet_id;
    
    -- Générer les données de la carte
    card_number := generate_virtual_card_number();
    cvv := generate_cvv();
    expiry_year := EXTRACT(YEAR FROM (NOW() + INTERVAL '3 years'))::VARCHAR;
    expiry_month := LPAD(EXTRACT(MONTH FROM NOW())::INTEGER, 2, '0');
    
    -- Créer la carte virtuelle automatiquement
    INSERT INTO virtual_cards (
        user_id, 
        wallet_id, 
        card_number, 
        card_holder_name, 
        expiry_month, 
        expiry_year, 
        cvv,
        card_type,
        card_status
    )
    VALUES (
        NEW.id,
        new_wallet_id,
        card_number,
        COALESCE(NEW.full_name, NEW.email, 'Utilisateur 224Solutions'),
        expiry_month,
        expiry_year,
        cvv,
        'virtual',
        'active'
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger automatique pour la création wallet + carte lors de l'inscription
CREATE TRIGGER auto_create_wallet_and_card
    AFTER INSERT ON profiles
    FOR EACH ROW
    EXECUTE FUNCTION create_user_wallet_and_card();

-- ===================================================
-- DONNÉES DE CONFIGURATION INITIALES
-- ===================================================

-- Configuration des commissions par défaut
INSERT INTO commission_config (service_name, transaction_type, commission_type, commission_value, min_commission, max_commission) VALUES
-- Mobile Money
('orange_money', 'mobile_money_in', 'percentage', 1.5, 100, 5000),
('orange_money', 'mobile_money_out', 'percentage', 2.0, 150, 7500),
('mtn_momo', 'mobile_money_in', 'percentage', 1.5, 100, 5000),
('mtn_momo', 'mobile_money_out', 'percentage', 2.0, 150, 7500),

-- Cartes bancaires
('visa', 'card_payment', 'percentage', 2.5, 50, 10000),
('mastercard', 'card_payment', 'percentage', 2.5, 50, 10000),

-- Transferts internes
('internal', 'transfer', 'percentage', 0.5, 25, 1000),
('internal', 'payment', 'percentage', 1.0, 50, 2000),

-- Virements bancaires
('bank_transfer', 'bank_transfer', 'fixed', 500, 500, 500);

-- Insertion d'un résumé initial pour aujourd'hui
INSERT INTO daily_revenue_summary (date, total_transactions, total_volume, total_commissions)
VALUES (CURRENT_DATE, 0, 0.00, 0.00)
ON CONFLICT (date) DO NOTHING;

-- ===================================================
-- POLITIQUES RLS (Row Level Security)
-- ===================================================

-- Activer RLS sur toutes les tables sensibles
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE collected_commissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE fraud_detection_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_revenue_summary ENABLE ROW LEVEL SECURITY;
ALTER TABLE revenue_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE commission_config ENABLE ROW LEVEL SECURITY;

-- Politique pour les wallets : utilisateurs peuvent voir leur propre wallet
CREATE POLICY wallet_owner_access ON wallets
    FOR ALL USING (
        auth.uid() = user_id OR 
        EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg'))
    );

-- Politique pour les transactions : utilisateurs peuvent voir leurs propres transactions
CREATE POLICY transaction_participant_access ON wallet_transactions
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM wallets 
            WHERE (id = sender_wallet_id OR id = receiver_wallet_id) 
            AND user_id = auth.uid()
        ) OR
        EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg'))
    );

-- Politique pour les commissions : seulement PDG/Admin
CREATE POLICY commission_admin_access ON collected_commissions
    FOR ALL USING (
        EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg'))
    );

-- Politique pour les logs de fraude : seulement PDG/Admin
CREATE POLICY fraud_admin_access ON fraud_detection_logs
    FOR ALL USING (
        EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg'))
    );

-- Politique pour les revenus : seulement PDG/Admin
CREATE POLICY revenue_admin_access ON daily_revenue_summary
    FOR ALL USING (
        EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg'))
    );

-- Politique pour les alertes : seulement PDG/Admin
CREATE POLICY alerts_admin_access ON revenue_alerts
    FOR ALL USING (
        EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg'))
    );

-- Politique pour la configuration : seulement PDG/Admin
CREATE POLICY config_admin_access ON commission_config
    FOR ALL USING (
        EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg'))
    );

-- Accorder les permissions nécessaires
GRANT USAGE ON SCHEMA public TO authenticated, anon;
GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;

