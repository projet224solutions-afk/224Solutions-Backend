-- Migration pour le système de gestion d'agents 224Solutions
-- Créé le: 2024-12-01

-- Extensions nécessaires
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Types énumérés
CREATE TYPE public.user_status AS ENUM ('invited', 'active', 'suspended');
CREATE TYPE public.commission_source_type AS ENUM ('user', 'sub_agent_user');
CREATE TYPE public.device_type AS ENUM ('mobile', 'pc', 'tablet');
CREATE TYPE public.notification_type AS ENUM ('email', 'sms', 'both');

-- =====================================================
-- Table PDG (Président Directeur Général)
-- =====================================================
CREATE TABLE public.pdg (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(20),
    permissions TEXT[] DEFAULT ARRAY['all'],
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- Table des Agents principaux
-- =====================================================
CREATE TABLE public.agents (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(20) NOT NULL,
    pdg_id UUID REFERENCES public.pdg(id) ON DELETE CASCADE,
    can_create_sub_agent BOOLEAN DEFAULT false,
    is_active BOOLEAN DEFAULT true,
    permissions TEXT[] DEFAULT ARRAY[],
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- Table des Sous-agents
-- =====================================================
CREATE TABLE public.sub_agents (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(20) NOT NULL,
    parent_agent_id UUID REFERENCES public.agents(id) ON DELETE CASCADE,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- Table des Utilisateurs finaux
-- =====================================================
CREATE TABLE public.agent_users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255),
    phone VARCHAR(20),
    creator_id UUID NOT NULL, -- Peut être agent_id ou sub_agent_id
    creator_type VARCHAR(20) NOT NULL CHECK (creator_type IN ('agent', 'sub_agent')),
    status public.user_status DEFAULT 'invited',
    invite_token VARCHAR(255) UNIQUE,
    activation_link TEXT,
    device_type public.device_type,
    activated_at TIMESTAMP WITH TIME ZONE,
    last_login TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Contraintes
    CONSTRAINT email_or_phone_required CHECK (email IS NOT NULL OR phone IS NOT NULL)
);

-- =====================================================
-- Table des Paramètres de Commission (configurable par PDG)
-- =====================================================
CREATE TABLE public.commission_settings (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    setting_key VARCHAR(50) UNIQUE NOT NULL,
    setting_value DECIMAL(5,4) NOT NULL, -- Pourcentage avec 4 décimales
    description TEXT,
    updated_by UUID REFERENCES public.pdg(id),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Insérer les paramètres par défaut
INSERT INTO public.commission_settings (setting_key, setting_value, description) VALUES
('base_user_commission', 0.2000, 'Commission de base par utilisateur (20% du revenu net)'),
('parent_share_ratio', 0.5000, 'Ratio de partage avec l''agent parent (50% = répartition 50/50)');

-- =====================================================
-- Table des Commissions
-- =====================================================
CREATE TABLE public.commissions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    recipient_id UUID NOT NULL,
    recipient_type VARCHAR(20) NOT NULL CHECK (recipient_type IN ('agent', 'sub_agent')),
    amount DECIMAL(12,2) NOT NULL,
    source_type public.commission_source_type NOT NULL,
    source_user_id UUID REFERENCES public.agent_users(id),
    transaction_id UUID, -- Référence à la transaction qui génère la commission
    commission_rate DECIMAL(5,4) NOT NULL, -- Taux appliqué pour traçabilité
    calculated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    paid_at TIMESTAMP WITH TIME ZONE,
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'paid', 'cancelled')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- Table des Transactions (revenus de l'application)
-- =====================================================
CREATE TABLE public.agent_transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.agent_users(id) ON DELETE CASCADE,
    gross_amount DECIMAL(12,2) NOT NULL, -- Montant brut
    fees DECIMAL(12,2) DEFAULT 0, -- Frais techniques
    taxes DECIMAL(12,2) DEFAULT 0, -- Taxes
    net_amount DECIMAL(12,2) NOT NULL, -- Montant net pour calcul commission
    transaction_type VARCHAR(50) DEFAULT 'user_activity',
    description TEXT,
    metadata JSONB DEFAULT '{}',
    processed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- Table d'Audit/Logs
-- =====================================================
CREATE TABLE public.agent_audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    actor_id UUID, -- Qui a fait l'action
    actor_type VARCHAR(20), -- 'pdg', 'agent', 'sub_agent'
    action VARCHAR(100) NOT NULL, -- 'create_user', 'activate_user', 'calculate_commission', etc.
    target_id UUID, -- Sur qui/quoi
    target_type VARCHAR(20), -- 'user', 'agent', 'commission', etc.
    details JSONB DEFAULT '{}',
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- Table des Invitations (tracking des liens)
-- =====================================================
CREATE TABLE public.user_invitations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.agent_users(id) ON DELETE CASCADE,
    invite_token VARCHAR(255) UNIQUE NOT NULL,
    invite_link TEXT NOT NULL,
    sent_via public.notification_type NOT NULL,
    sent_to VARCHAR(255) NOT NULL, -- email ou numéro
    sent_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    opened_at TIMESTAMP WITH TIME ZONE,
    activated_at TIMESTAMP WITH TIME ZONE,
    expires_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() + INTERVAL '7 days'),
    is_expired BOOLEAN DEFAULT false
);

-- =====================================================
-- INDEXES pour les performances
-- =====================================================
CREATE INDEX idx_agents_pdg_id ON public.agents(pdg_id);
CREATE INDEX idx_sub_agents_parent_id ON public.sub_agents(parent_agent_id);
CREATE INDEX idx_agent_users_creator ON public.agent_users(creator_id, creator_type);
CREATE INDEX idx_agent_users_status ON public.agent_users(status);
CREATE INDEX idx_commissions_recipient ON public.commissions(recipient_id, recipient_type);
CREATE INDEX idx_commissions_source ON public.commissions(source_user_id);
CREATE INDEX idx_transactions_user_id ON public.agent_transactions(user_id);
CREATE INDEX idx_transactions_processed_at ON public.agent_transactions(processed_at);
CREATE INDEX idx_audit_logs_actor ON public.agent_audit_logs(actor_id, actor_type);
CREATE INDEX idx_audit_logs_created_at ON public.agent_audit_logs(created_at);
CREATE INDEX idx_invitations_token ON public.user_invitations(invite_token);
CREATE INDEX idx_invitations_user_id ON public.user_invitations(user_id);

-- =====================================================
-- TRIGGERS pour mise à jour automatique
-- =====================================================

-- Trigger pour updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Appliquer le trigger aux tables appropriées
CREATE TRIGGER update_agents_updated_at BEFORE UPDATE ON public.agents 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_sub_agents_updated_at BEFORE UPDATE ON public.sub_agents 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_agent_users_updated_at BEFORE UPDATE ON public.agent_users 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- =====================================================
-- FONCTIONS UTILITAIRES
-- =====================================================

-- Fonction pour générer un token d'invitation unique
CREATE OR REPLACE FUNCTION generate_invite_token()
RETURNS TEXT AS $$
BEGIN
    RETURN encode(gen_random_bytes(32), 'base64url');
END;
$$ LANGUAGE plpgsql;

-- Fonction pour calculer les commissions automatiquement
CREATE OR REPLACE FUNCTION calculate_user_commission(p_user_id UUID, p_net_amount DECIMAL)
RETURNS TABLE(recipient_id UUID, recipient_type TEXT, amount DECIMAL, commission_rate DECIMAL) AS $$
DECLARE
    v_user RECORD;
    v_base_commission DECIMAL;
    v_parent_share_ratio DECIMAL;
    v_agent_amount DECIMAL;
    v_sub_agent_amount DECIMAL;
    v_parent_amount DECIMAL;
BEGIN
    -- Récupérer l'utilisateur
    SELECT * INTO v_user FROM public.agent_users WHERE id = p_user_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'User not found: %', p_user_id;
    END IF;
    
    -- Récupérer les paramètres de commission
    SELECT setting_value INTO v_base_commission 
    FROM public.commission_settings 
    WHERE setting_key = 'base_user_commission';
    
    SELECT setting_value INTO v_parent_share_ratio 
    FROM public.commission_settings 
    WHERE setting_key = 'parent_share_ratio';
    
    -- Valeurs par défaut si non configurées
    v_base_commission := COALESCE(v_base_commission, 0.2);
    v_parent_share_ratio := COALESCE(v_parent_share_ratio, 0.5);
    
    IF v_user.creator_type = 'agent' THEN
        -- Utilisateur créé par un agent : l'agent reçoit tout
        v_agent_amount := p_net_amount * v_base_commission;
        
        RETURN QUERY SELECT 
            v_user.creator_id,
            'agent'::TEXT,
            v_agent_amount,
            v_base_commission;
            
    ELSIF v_user.creator_type = 'sub_agent' THEN
        -- Utilisateur créé par un sous-agent : répartition
        v_sub_agent_amount := p_net_amount * v_base_commission * (1 - v_parent_share_ratio);
        v_parent_amount := p_net_amount * v_base_commission * v_parent_share_ratio;
        
        -- Commission pour le sous-agent
        RETURN QUERY SELECT 
            v_user.creator_id,
            'sub_agent'::TEXT,
            v_sub_agent_amount,
            v_base_commission * (1 - v_parent_share_ratio);
        
        -- Commission pour l'agent parent
        RETURN QUERY SELECT 
            (SELECT parent_agent_id FROM public.sub_agents WHERE id = v_user.creator_id),
            'agent'::TEXT,
            v_parent_amount,
            v_base_commission * v_parent_share_ratio;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- POLITIQUES RLS (Row Level Security)
-- =====================================================

-- Activer RLS sur les tables sensibles
ALTER TABLE public.agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sub_agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commissions ENABLE ROW LEVEL SECURITY;

-- Politiques pour les agents (peuvent voir leurs propres données et celles de leurs sous-agents)
CREATE POLICY "Agents can view their own data" ON public.agents
    FOR ALL USING (auth.uid()::text = id::text);

CREATE POLICY "Sub-agents can view their own data" ON public.sub_agents
    FOR ALL USING (auth.uid()::text = id::text);

-- Politiques pour les utilisateurs
CREATE POLICY "Creators can view their users" ON public.agent_users
    FOR ALL USING (auth.uid()::text = creator_id::text);

-- =====================================================
-- COMMENTAIRES POUR DOCUMENTATION
-- =====================================================
COMMENT ON TABLE public.pdg IS 'Table des Présidents Directeurs Généraux avec permissions complètes';
COMMENT ON TABLE public.agents IS 'Table des agents principaux créés par le PDG';
COMMENT ON TABLE public.sub_agents IS 'Table des sous-agents créés par les agents autorisés';
COMMENT ON TABLE public.agent_users IS 'Table des utilisateurs finaux créés par agents ou sous-agents';
COMMENT ON TABLE public.commission_settings IS 'Paramètres configurables des taux de commission';
COMMENT ON TABLE public.commissions IS 'Historique des commissions calculées et versées';
COMMENT ON TABLE public.agent_transactions IS 'Transactions générant des revenus et commissions';
COMMENT ON TABLE public.agent_audit_logs IS 'Logs d''audit pour traçabilité complète';
COMMENT ON TABLE public.user_invitations IS 'Suivi des invitations envoyées aux utilisateurs';

COMMENT ON FUNCTION calculate_user_commission IS 'Calcule automatiquement les commissions selon la hiérarchie agent/sous-agent';
COMMENT ON FUNCTION generate_invite_token IS 'Génère un token unique pour les liens d''invitation';

-- =====================================================
-- DONNÉES DE TEST (à supprimer en production)
-- =====================================================

-- Créer un PDG de test
INSERT INTO public.pdg (id, name, email, phone) VALUES 
('550e8400-e29b-41d4-a716-446655440000', 'PDG Test 224Solutions', 'pdg@224solution.net', '+221 77 123 45 67');

-- Créer un agent de test
INSERT INTO public.agents (id, name, email, phone, pdg_id, can_create_sub_agent) VALUES 
('550e8400-e29b-41d4-a716-446655440001', 'Agent Principal Test', 'agent@224solution.net', '+221 77 234 56 78', '550e8400-e29b-41d4-a716-446655440000', true);

-- Créer un sous-agent de test
INSERT INTO public.sub_agents (id, name, email, phone, parent_agent_id) VALUES 
('550e8400-e29b-41d4-a716-446655440002', 'Sous-Agent Test', 'subagent@224solution.net', '+221 77 345 67 89', '550e8400-e29b-41d4-a716-446655440001');
