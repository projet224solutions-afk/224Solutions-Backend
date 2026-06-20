-- =====================================================
-- SYSTÈME WALLET AUTOMATIQUE - 224SOLUTIONS
-- =====================================================
-- Date: 2 janvier 2025
-- Version: 1.0.0
-- Description: Système complet de portefeuilles avec création automatique

-- Extensions nécessaires
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =====================================================
-- 1. WALLETS (PORTEFEUILLES)
-- =====================================================

-- Types énumérés
CREATE TYPE wallet_status AS ENUM ('active', 'suspended', 'closed');
CREATE TYPE transaction_type AS ENUM ('credit', 'debit', 'transfer');
CREATE TYPE transaction_status AS ENUM ('pending', 'completed', 'failed', 'cancelled');

-- Table des wallets
CREATE TABLE IF NOT EXISTS wallets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    balance DECIMAL(15, 2) DEFAULT 0.00,
    currency VARCHAR(10) DEFAULT 'FCFA',
    status wallet_status DEFAULT 'active',
    wallet_address VARCHAR(100) UNIQUE NOT NULL,
    
    -- Métadonnées
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Contraintes
    CONSTRAINT positive_balance CHECK (balance >= 0),
    CONSTRAINT valid_currency CHECK (currency IN ('FCFA', 'USD', 'EUR')),
    UNIQUE(user_id) -- Un seul wallet par utilisateur
);

-- =====================================================
-- 2. TRANSACTIONS WALLET
-- =====================================================

-- Table des transactions
CREATE TABLE IF NOT EXISTS wallet_transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    wallet_id UUID NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
    
    -- Détails transaction
    type transaction_type NOT NULL,
    amount DECIMAL(15, 2) NOT NULL,
    currency VARCHAR(10) DEFAULT 'FCFA',
    description TEXT NOT NULL,
    reference VARCHAR(100) UNIQUE NOT NULL,
    status transaction_status DEFAULT 'pending',
    
    -- Transferts (optionnel)
    from_wallet_id UUID REFERENCES wallets(id),
    to_wallet_id UUID REFERENCES wallets(id),
    
    -- Métadonnées
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Contraintes
    CONSTRAINT positive_amount CHECK (amount > 0),
    CONSTRAINT valid_transfer CHECK (
        (type = 'transfer' AND from_wallet_id IS NOT NULL AND to_wallet_id IS NOT NULL) OR
        (type != 'transfer')
    )
);

-- =====================================================
-- 3. HISTORIQUE DES SOLDES
-- =====================================================

-- Table pour tracker l'historique des soldes
CREATE TABLE IF NOT EXISTS wallet_balance_history (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    wallet_id UUID NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
    old_balance DECIMAL(15, 2) NOT NULL,
    new_balance DECIMAL(15, 2) NOT NULL,
    transaction_id UUID REFERENCES wallet_transactions(id),
    reason VARCHAR(255),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 4. PARAMÈTRES WALLET
-- =====================================================

-- Table des paramètres utilisateur pour les wallets
CREATE TABLE IF NOT EXISTS wallet_settings (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    
    -- Paramètres de notification
    notify_on_credit BOOLEAN DEFAULT true,
    notify_on_debit BOOLEAN DEFAULT true,
    notify_on_low_balance BOOLEAN DEFAULT true,
    low_balance_threshold DECIMAL(15, 2) DEFAULT 1000.00,
    
    -- Paramètres de sécurité
    require_pin_for_transfers BOOLEAN DEFAULT false,
    daily_transfer_limit DECIMAL(15, 2) DEFAULT 100000.00,
    monthly_transfer_limit DECIMAL(15, 2) DEFAULT 1000000.00,
    
    -- Métadonnées
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    UNIQUE(user_id)
);

-- =====================================================
-- 5. INDEX POUR PERFORMANCE
-- =====================================================

-- Index sur les wallets
CREATE INDEX IF NOT EXISTS idx_wallets_user_id ON wallets(user_id);
CREATE INDEX IF NOT EXISTS idx_wallets_status ON wallets(status);
CREATE INDEX IF NOT EXISTS idx_wallets_address ON wallets(wallet_address);

-- Index sur les transactions
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_wallet_id ON wallet_transactions(wallet_id);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_type ON wallet_transactions(type);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_status ON wallet_transactions(status);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_created_at ON wallet_transactions(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_reference ON wallet_transactions(reference);

-- Index sur l'historique
CREATE INDEX IF NOT EXISTS idx_wallet_balance_history_wallet_id ON wallet_balance_history(wallet_id);
CREATE INDEX IF NOT EXISTS idx_wallet_balance_history_created_at ON wallet_balance_history(created_at DESC);

-- =====================================================
-- 6. FONCTIONS UTILITAIRES
-- =====================================================

-- Fonction pour créer automatiquement un wallet à l'inscription
CREATE OR REPLACE FUNCTION create_user_wallet()
RETURNS TRIGGER AS $$
DECLARE
    wallet_address VARCHAR(100);
BEGIN
    -- Générer une adresse wallet unique
    wallet_address := '224SOL_' || SUBSTRING(NEW.id::text, 1, 8) || '_' || EXTRACT(EPOCH FROM NOW())::bigint || '_' || SUBSTRING(MD5(RANDOM()::text), 1, 8);
    wallet_address := UPPER(wallet_address);
    
    -- Créer le wallet
    INSERT INTO wallets (user_id, wallet_address, balance, currency, status)
    VALUES (NEW.id, wallet_address, 0.00, 'FCFA', 'active');
    
    -- Créer les paramètres par défaut
    INSERT INTO wallet_settings (user_id)
    VALUES (NEW.id);
    
    -- Créer une transaction d'ouverture
    INSERT INTO wallet_transactions (
        wallet_id, 
        type, 
        amount, 
        currency, 
        description, 
        reference, 
        status
    )
    SELECT 
        w.id,
        'credit',
        0.00,
        'FCFA',
        'Ouverture de compte wallet 224Solutions',
        'OPENING_' || EXTRACT(EPOCH FROM NOW())::bigint,
        'completed'
    FROM wallets w 
    WHERE w.user_id = NEW.id;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour mettre à jour l'historique des soldes
CREATE OR REPLACE FUNCTION update_balance_history()
RETURNS TRIGGER AS $$
BEGIN
    -- Enregistrer le changement de solde
    INSERT INTO wallet_balance_history (
        wallet_id,
        old_balance,
        new_balance,
        reason
    )
    VALUES (
        NEW.id,
        COALESCE(OLD.balance, 0),
        NEW.balance,
        'Balance update'
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour calculer les statistiques d'un wallet
CREATE OR REPLACE FUNCTION get_wallet_stats(wallet_id_param UUID)
RETURNS JSON AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'total_transactions', COUNT(*),
        'total_credits', COALESCE(SUM(CASE WHEN type = 'credit' AND status = 'completed' THEN amount ELSE 0 END), 0),
        'total_debits', COALESCE(SUM(CASE WHEN type = 'debit' AND status = 'completed' THEN amount ELSE 0 END), 0),
        'pending_transactions', COUNT(CASE WHEN status = 'pending' THEN 1 END),
        'monthly_volume', COALESCE(SUM(CASE 
            WHEN DATE_TRUNC('month', created_at) = DATE_TRUNC('month', NOW()) 
            AND status = 'completed' 
            THEN amount ELSE 0 END), 0)
    ) INTO result
    FROM wallet_transactions
    WHERE wallet_id = wallet_id_param;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 7. TRIGGERS
-- =====================================================

-- Trigger pour créer automatiquement un wallet à l'inscription
CREATE TRIGGER trigger_create_user_wallet
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION create_user_wallet();

-- Trigger pour l'historique des soldes
CREATE TRIGGER trigger_wallet_balance_history
    AFTER UPDATE OF balance ON wallets
    FOR EACH ROW
    WHEN (OLD.balance IS DISTINCT FROM NEW.balance)
    EXECUTE FUNCTION update_balance_history();

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_wallets_updated_at
    BEFORE UPDATE ON wallets
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trigger_wallet_transactions_updated_at
    BEFORE UPDATE ON wallet_transactions
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trigger_wallet_settings_updated_at
    BEFORE UPDATE ON wallet_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- =====================================================
-- 8. RLS (ROW LEVEL SECURITY)
-- =====================================================

-- Activer RLS sur toutes les tables
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_balance_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_settings ENABLE ROW LEVEL SECURITY;

-- Politiques pour wallets
CREATE POLICY "Users can view their own wallet" ON wallets
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can update their own wallet" ON wallets
    FOR UPDATE USING (auth.uid() = user_id);

-- Politiques pour transactions
CREATE POLICY "Users can view their wallet transactions" ON wallet_transactions
    FOR SELECT USING (
        wallet_id IN (SELECT id FROM wallets WHERE user_id = auth.uid())
    );

CREATE POLICY "Users can create transactions for their wallet" ON wallet_transactions
    FOR INSERT WITH CHECK (
        wallet_id IN (SELECT id FROM wallets WHERE user_id = auth.uid())
    );

-- Politiques pour l'historique
CREATE POLICY "Users can view their wallet history" ON wallet_balance_history
    FOR SELECT USING (
        wallet_id IN (SELECT id FROM wallets WHERE user_id = auth.uid())
    );

-- Politiques pour les paramètres
CREATE POLICY "Users can manage their wallet settings" ON wallet_settings
    FOR ALL USING (auth.uid() = user_id);

-- =====================================================
-- 9. DONNÉES INITIALES
-- =====================================================

-- Créer des wallets pour les utilisateurs existants (si ils n'en ont pas)
INSERT INTO wallets (user_id, wallet_address, balance, currency, status)
SELECT 
    u.id,
    '224SOL_' || SUBSTRING(u.id::text, 1, 8) || '_' || EXTRACT(EPOCH FROM NOW())::bigint || '_' || SUBSTRING(MD5(RANDOM()::text), 1, 8),
    0.00,
    'FCFA',
    'active'
FROM auth.users u
WHERE u.id NOT IN (SELECT user_id FROM wallets)
ON CONFLICT (user_id) DO NOTHING;

-- Créer les paramètres pour les utilisateurs existants
INSERT INTO wallet_settings (user_id)
SELECT u.id
FROM auth.users u
WHERE u.id NOT IN (SELECT user_id FROM wallet_settings)
ON CONFLICT (user_id) DO NOTHING;

-- =====================================================
-- COMMENTAIRES ET DOCUMENTATION
-- =====================================================

COMMENT ON TABLE wallets IS 'Portefeuilles utilisateurs avec création automatique';
COMMENT ON TABLE wallet_transactions IS 'Transactions des portefeuilles avec historique complet';
COMMENT ON TABLE wallet_balance_history IS 'Historique des changements de solde';
COMMENT ON TABLE wallet_settings IS 'Paramètres personnalisés des portefeuilles';

COMMENT ON FUNCTION create_user_wallet IS 'Crée automatiquement un wallet lors de l\'inscription';
COMMENT ON FUNCTION get_wallet_stats IS 'Calcule les statistiques d\'un portefeuille';
COMMENT ON FUNCTION update_balance_history IS 'Met à jour l\'historique des soldes';
