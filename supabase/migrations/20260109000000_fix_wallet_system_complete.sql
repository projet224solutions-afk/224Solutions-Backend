-- =================================================================
-- MIGRATION CRITIQUE: Fix Wallet System Complet
-- Date: 2026-01-09
-- Objectif: Réparer le système wallet cassé
-- =================================================================

-- 1. SAUVEGARDER DONNÉES EXISTANTES AVANT SUPPRESSION
DO $$
BEGIN
    -- Créer table temporaire pour sauvegarder transactions si elle existe
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'wallet_transactions') THEN
        CREATE TEMP TABLE temp_wallet_transactions AS 
        SELECT * FROM wallet_transactions;
        RAISE NOTICE '✅ Sauvegarde de % transactions existantes', (SELECT COUNT(*) FROM temp_wallet_transactions);
    END IF;
    
    -- Créer table temporaire pour sauvegarder wallets si elle existe
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'wallets') THEN
        CREATE TEMP TABLE temp_wallets AS 
        SELECT * FROM wallets;
        RAISE NOTICE '✅ Sauvegarde de % wallets existants', (SELECT COUNT(*) FROM temp_wallets);
    END IF;
END $$;

-- 2. SUPPRIMER LES DOUBLONS ET INCONSISTANCES
DROP TABLE IF EXISTS enhanced_transactions CASCADE;
DROP TABLE IF EXISTS wallet_transactions CASCADE;
DROP TABLE IF EXISTS wallets CASCADE;
DROP TYPE IF EXISTS wallet_status CASCADE;
DROP TYPE IF EXISTS transaction_type CASCADE;
DROP TYPE IF EXISTS transaction_status CASCADE;
DROP TYPE IF EXISTS commission_type CASCADE;

-- 4. CRÉER LES TYPES ENUM
CREATE TYPE wallet_status AS ENUM ('active', 'suspended', 'blocked', 'pending_verification');
CREATE TYPE transaction_type AS ENUM (
    'transfer', 'deposit', 'withdrawal', 'payment', 'refund', 
    'commission', 'mobile_money_in', 'mobile_money_out', 
    'card_payment', 'bank_transfer'
);
CREATE TYPE transaction_status AS ENUM (
    'pending', 'processing', 'completed', 'failed', 
    'cancelled', 'refunded', 'disputed'
);
CREATE TYPE commission_type AS ENUM ('percentage', 'fixed', 'tiered');

-- 5. CRÉER TABLE WALLETS (Schema Unifié)
CREATE TABLE wallets (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID UNIQUE NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    balance DECIMAL(15,2) DEFAULT 0 CHECK (balance >= 0),
    currency VARCHAR(3) DEFAULT 'GNF', -- ✅ Guinée Franc
    wallet_status wallet_status DEFAULT 'active',
    is_blocked BOOLEAN DEFAULT false,
    blocked_reason TEXT,
    blocked_at TIMESTAMPTZ,
    pin_hash VARCHAR(255),
    biometric_enabled BOOLEAN DEFAULT false,
    daily_limit DECIMAL(15,2) DEFAULT 5000000.00, -- 5M GNF/jour
    monthly_limit DECIMAL(15,2) DEFAULT 50000000.00, -- 50M GNF/mois
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index performance
CREATE INDEX idx_wallets_user_id ON wallets(user_id);
CREATE INDEX idx_wallets_status ON wallets(wallet_status) WHERE wallet_status = 'active';

-- 6. TABLE TRANSACTIONS (Unifiée)
CREATE TABLE wallet_transactions (
    id BIGSERIAL PRIMARY KEY,
    transaction_id VARCHAR(50) UNIQUE NOT NULL,
    
    -- Références wallets ET users (pour compatibilité)
    sender_wallet_id BIGINT REFERENCES wallets(id),
    receiver_wallet_id BIGINT REFERENCES wallets(id),
    sender_user_id UUID REFERENCES profiles(id),
    receiver_user_id UUID REFERENCES profiles(id),
    
    -- Montants
    amount DECIMAL(15,2) NOT NULL CHECK (amount > 0),
    fee DECIMAL(15,2) DEFAULT 0.00 CHECK (fee >= 0),
    net_amount DECIMAL(15,2) NOT NULL CHECK (net_amount = amount - fee),
    currency VARCHAR(3) DEFAULT 'GNF',
    
    -- Métadata
    transaction_type transaction_type NOT NULL,
    status transaction_status DEFAULT 'pending',
    description TEXT,
    reference_id VARCHAR(100),
    metadata JSONB DEFAULT '{}',
    
    -- Sécurité
    signature VARCHAR(255), -- HMAC signature
    signature_verified BOOLEAN DEFAULT false,
    ip_address INET,
    device_info JSONB,
    idempotency_key VARCHAR(100) UNIQUE,
    
    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    
    -- Contraintes
    CONSTRAINT different_wallets CHECK (
        sender_wallet_id IS NULL OR 
        receiver_wallet_id IS NULL OR 
        sender_wallet_id != receiver_wallet_id
    )
);

-- Index pour performance
CREATE INDEX idx_wallet_tx_sender_user ON wallet_transactions(sender_user_id, created_at DESC);
CREATE INDEX idx_wallet_tx_receiver_user ON wallet_transactions(receiver_user_id, created_at DESC);
CREATE INDEX idx_wallet_tx_sender_wallet ON wallet_transactions(sender_wallet_id);
CREATE INDEX idx_wallet_tx_receiver_wallet ON wallet_transactions(receiver_wallet_id);
CREATE INDEX idx_wallet_tx_status ON wallet_transactions(status, created_at DESC);
CREATE INDEX idx_wallet_tx_idempotency ON wallet_transactions(idempotency_key) WHERE idempotency_key IS NOT NULL;

-- 7. RESTAURER WALLETS EXISTANTS
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pg_temp' AND tablename LIKE 'temp_wallets%') THEN
        INSERT INTO wallets (id, user_id, balance, currency, wallet_status, is_blocked, blocked_reason, blocked_at, created_at, updated_at)
        SELECT 
            id, 
            user_id, 
            COALESCE(balance, 0),
            COALESCE(currency, 'GNF'),
            CASE 
                WHEN is_blocked THEN 'blocked'::wallet_status
                ELSE 'active'::wallet_status
            END,
            COALESCE(is_blocked, false),
            blocked_reason,
            blocked_at,
            COALESCE(created_at, NOW()),
            COALESCE(updated_at, NOW())
        FROM temp_wallets
        ON CONFLICT (user_id) DO UPDATE SET
            balance = EXCLUDED.balance,
            currency = EXCLUDED.currency,
            updated_at = NOW();
            
        RAISE NOTICE '✅ Restauré % wallets', (SELECT COUNT(*) FROM temp_wallets);
    END IF;
END $$;

-- 8. RESTAURER TRANSACTIONS EXISTANTES
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'pg_temp' AND tablename LIKE 'temp_wallet_transactions%') THEN
        -- Restaurer transactions avec mise à jour des user_ids
        INSERT INTO wallet_transactions (
            id, transaction_id, sender_wallet_id, receiver_wallet_id, 
            sender_user_id, receiver_user_id,
            amount, fee, net_amount, currency,
            transaction_type, status, description, reference_id, metadata,
            signature, signature_verified, ip_address, device_info, idempotency_key,
            created_at, updated_at, completed_at
        )
        SELECT 
            t.id,
            COALESCE(t.transaction_id, 'TX-' || t.id),
            t.sender_wallet_id,
            t.receiver_wallet_id,
            -- Récupérer user_id depuis wallets
            COALESCE(t.sender_user_id, (SELECT user_id FROM wallets WHERE id = t.sender_wallet_id)),
            COALESCE(t.receiver_user_id, (SELECT user_id FROM wallets WHERE id = t.receiver_wallet_id)),
            t.amount,
            COALESCE(t.fee, 0),
            COALESCE(t.net_amount, t.amount - COALESCE(t.fee, 0)),
            COALESCE(t.currency, 'GNF'),
            COALESCE(t.transaction_type::text, 'transfer')::transaction_type,
            COALESCE(t.status::text, 'completed')::transaction_status,
            t.description,
            t.reference_id,
            COALESCE(t.metadata, '{}'::jsonb),
            t.signature,
            COALESCE(t.signature_verified, false),
            t.ip_address,
            t.device_info,
            t.idempotency_key,
            COALESCE(t.created_at, NOW()),
            COALESCE(t.updated_at, NOW()),
            t.completed_at
        FROM temp_wallet_transactions t
        ON CONFLICT (transaction_id) DO NOTHING;
        
        RAISE NOTICE '✅ Restauré % transactions', (SELECT COUNT(*) FROM temp_wallet_transactions);
    END IF;
END $$;

-- 9. FONCTION ATOMIQUE: Update Balance
CREATE OR REPLACE FUNCTION update_wallet_balance_atomic(
    p_wallet_id BIGINT,
    p_amount DECIMAL,
    p_transaction_id VARCHAR,
    p_description TEXT DEFAULT NULL
)
RETURNS TABLE(new_balance DECIMAL, success BOOLEAN) AS $$
DECLARE
    v_current_balance DECIMAL;
    v_new_balance DECIMAL;
    v_user_id UUID;
BEGIN
    -- 🔒 LOCK la ligne pour éviter race conditions
    SELECT balance, user_id INTO v_current_balance, v_user_id
    FROM wallets
    WHERE id = p_wallet_id
    FOR UPDATE;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Wallet % non trouvé', p_wallet_id;
    END IF;
    
    -- Calculer nouveau solde
    v_new_balance := v_current_balance + p_amount;
    
    -- Vérifier solde négatif
    IF v_new_balance < 0 THEN
        RAISE EXCEPTION 'Solde insuffisant: % + % = % < 0', v_current_balance, p_amount, v_new_balance;
    END IF;
    
    -- Update atomique
    UPDATE wallets
    SET 
        balance = v_new_balance,
        updated_at = NOW()
    WHERE id = p_wallet_id;
    
    -- Logger dans audit
    INSERT INTO financial_audit_logs (user_id, action_type, description, request_data)
    VALUES (
        v_user_id,
        'wallet_balance_update',
        COALESCE(p_description, 'Balance update'),
        jsonb_build_object(
            'wallet_id', p_wallet_id,
            'old_balance', v_current_balance,
            'new_balance', v_new_balance,
            'amount', p_amount,
            'transaction_id', p_transaction_id
        )
    );
    
    RETURN QUERY SELECT v_new_balance, true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 10. FONCTION: Create Wallet Auto
CREATE OR REPLACE FUNCTION create_wallet_for_user(p_user_id UUID)
RETURNS BIGINT AS $$
DECLARE
    v_wallet_id BIGINT;
BEGIN
    -- Vérifier si wallet existe déjà
    SELECT id INTO v_wallet_id
    FROM wallets
    WHERE user_id = p_user_id;
    
    IF FOUND THEN
        RETURN v_wallet_id;
    END IF;
    
    -- Créer nouveau wallet
    INSERT INTO wallets (user_id, balance, currency, wallet_status)
    VALUES (p_user_id, 0, 'GNF', 'active')
    RETURNING id INTO v_wallet_id;
    
    RETURN v_wallet_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 11. TRIGGER: Auto-Create Wallet on Profile Insert
CREATE OR REPLACE FUNCTION trigger_create_wallet()
RETURNS TRIGGER AS $$
BEGIN
    -- Créer wallet automatiquement pour nouveau profil
    INSERT INTO wallets (user_id, balance, currency, wallet_status)
    VALUES (NEW.id, 0, 'GNF', 'active')
    ON CONFLICT (user_id) DO NOTHING;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_create_wallet_on_profile ON profiles;
CREATE TRIGGER trigger_create_wallet_on_profile
    AFTER INSERT ON profiles
    FOR EACH ROW
    EXECUTE FUNCTION trigger_create_wallet();

-- 12. RLS POLICIES
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;

-- Policy: Users can view own wallet
DROP POLICY IF EXISTS "Users view own wallet" ON wallets;
CREATE POLICY "Users view own wallet"
ON wallets FOR SELECT
USING (auth.uid() = user_id);

-- Policy: Service role full access
DROP POLICY IF EXISTS "Service role manage wallets" ON wallets;
CREATE POLICY "Service role manage wallets"
ON wallets FOR ALL
USING (auth.role() = 'service_role');

-- Policy: Users view own transactions
DROP POLICY IF EXISTS "Users view own transactions" ON wallet_transactions;
CREATE POLICY "Users view own transactions"
ON wallet_transactions FOR SELECT
USING (
    auth.uid() = sender_user_id OR 
    auth.uid() = receiver_user_id
);

-- Policy: Service role manage transactions
DROP POLICY IF EXISTS "Service role manage transactions" ON wallet_transactions;
CREATE POLICY "Service role manage transactions"
ON wallet_transactions FOR ALL
USING (auth.role() = 'service_role');

-- 13. TABLE: Idempotency Keys (Prevent Duplicates)
CREATE TABLE IF NOT EXISTS idempotency_keys (
    id BIGSERIAL PRIMARY KEY,
    key VARCHAR(100) UNIQUE NOT NULL,
    user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
    operation VARCHAR(50) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ DEFAULT NOW() + INTERVAL '24 hours'
);

CREATE INDEX idx_idempotency_key ON idempotency_keys(key);
CREATE INDEX idx_idempotency_expires ON idempotency_keys(expires_at);

-- 14. FONCTION: Check Idempotency
CREATE OR REPLACE FUNCTION check_idempotency_key(
    p_key VARCHAR,
    p_user_id UUID,
    p_operation VARCHAR
)
RETURNS BOOLEAN AS $$
DECLARE
    v_exists BOOLEAN;
BEGIN
    -- Nettoyer les clés expirées
    DELETE FROM idempotency_keys WHERE expires_at < NOW();
    
    -- Vérifier si la clé existe
    SELECT EXISTS (
        SELECT 1 FROM idempotency_keys
        WHERE key = p_key AND user_id = p_user_id
    ) INTO v_exists;
    
    IF v_exists THEN
        RETURN false; -- Duplicate request
    END IF;
    
    -- Enregistrer nouvelle clé
    INSERT INTO idempotency_keys (key, user_id, operation)
    VALUES (p_key, p_user_id, p_operation)
    ON CONFLICT (key) DO NOTHING;
    
    RETURN true; -- New request
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 15. CRÉER WALLETS MANQUANTS POUR USERS EXISTANTS
INSERT INTO wallets (user_id, balance, currency, wallet_status)
SELECT id, 0, 'GNF', 'active'
FROM profiles
WHERE NOT EXISTS (
    SELECT 1 FROM wallets WHERE wallets.user_id = profiles.id
)
ON CONFLICT (user_id) DO NOTHING;

-- 16. VIEWS UTILES
CREATE OR REPLACE VIEW wallet_summary AS
SELECT 
    w.id as wallet_id,
    w.user_id,
    p.custom_id as user_code,
    p.role,
    w.balance,
    w.currency,
    w.wallet_status,
    w.is_blocked,
    COUNT(DISTINCT wt.id) FILTER (WHERE wt.sender_user_id = w.user_id) as sent_count,
    COUNT(DISTINCT wt.id) FILTER (WHERE wt.receiver_user_id = w.user_id) as received_count,
    COALESCE(SUM(wt.amount) FILTER (WHERE wt.sender_user_id = w.user_id AND wt.status = 'completed'), 0) as total_sent,
    COALESCE(SUM(wt.amount) FILTER (WHERE wt.receiver_user_id = w.user_id AND wt.status = 'completed'), 0) as total_received
FROM wallets w
LEFT JOIN profiles p ON w.user_id = p.id
LEFT JOIN wallet_transactions wt ON (wt.sender_user_id = w.user_id OR wt.receiver_user_id = w.user_id)
GROUP BY w.id, w.user_id, p.custom_id, p.role, w.balance, w.currency, w.wallet_status, w.is_blocked;

-- 17. GRANTS
GRANT SELECT ON wallet_summary TO authenticated;
GRANT SELECT ON wallet_summary TO anon;

-- =================================================================
-- FIN MIGRATION
-- =================================================================

-- Vérifications
DO $$
DECLARE
    wallet_count INTEGER;
    transaction_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO wallet_count FROM wallets;
    SELECT COUNT(*) INTO transaction_count FROM wallet_transactions;
    
    RAISE NOTICE '================================================';
    RAISE NOTICE '✅ MIGRATION WALLET SYSTEM COMPLÉTÉE';
    RAISE NOTICE '================================================';
    RAISE NOTICE '📊 Wallets créés: %', wallet_count;
    RAISE NOTICE '📊 Transactions: %', transaction_count;
    RAISE NOTICE '================================================';
    RAISE NOTICE '🔐 RLS activé: wallets, wallet_transactions';
    RAISE NOTICE '⚡ Fonction atomique: update_wallet_balance_atomic';
    RAISE NOTICE '🛡️ Idempotency: idempotency_keys table';
    RAISE NOTICE '👁️ View: wallet_summary';
    RAISE NOTICE '================================================';
END $$;
