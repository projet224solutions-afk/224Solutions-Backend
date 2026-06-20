-- =====================================================
-- SYSTÈME COMPLET DE GESTION D'AGENTS - 224SOLUTIONS
-- Migration complète pour agents, sous-agents, commissions
-- =====================================================

-- Extensions nécessaires
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Types énumérés pour le système d'agents
CREATE TYPE public.user_status_agent AS ENUM ('invited', 'active', 'suspended', 'inactive');
CREATE TYPE public.commission_source_type AS ENUM ('user', 'sub_agent_user');
CREATE TYPE public.device_type AS ENUM ('mobile', 'pc', 'tablet');
CREATE TYPE public.notification_type AS ENUM ('email', 'sms', 'both');

-- =====================================================
-- Table PDG (Président Directeur Général)
-- =====================================================
CREATE TABLE public.pdg_management (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(20),
    permissions TEXT[] DEFAULT ARRAY['all'],
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- Table des Agents principaux
-- =====================================================
CREATE TABLE public.agents_management (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_code VARCHAR(20) UNIQUE NOT NULL, -- Code unique agent (AGT-YYYY-XXXXX)
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    pdg_id UUID REFERENCES public.pdg_management(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(20) NOT NULL,
    can_create_sub_agent BOOLEAN DEFAULT false,
    is_active BOOLEAN DEFAULT true,
    permissions TEXT[] DEFAULT ARRAY[],
    total_users_created INTEGER DEFAULT 0,
    total_commissions_earned DECIMAL(15,2) DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- Table des Sous-agents
-- =====================================================
CREATE TABLE public.sub_agents_management (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sub_agent_code VARCHAR(20) UNIQUE NOT NULL, -- Code unique sous-agent (SUB-YYYY-XXXXX)
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    parent_agent_id UUID REFERENCES public.agents_management(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(20) NOT NULL,
    is_active BOOLEAN DEFAULT true,
    permissions TEXT[] DEFAULT ARRAY['create_users'],
    total_users_created INTEGER DEFAULT 0,
    total_commissions_earned DECIMAL(15,2) DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- Table des Utilisateurs créés par agents/sous-agents
-- =====================================================
CREATE TABLE public.agent_created_users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_code VARCHAR(20) UNIQUE NOT NULL, -- Code unique utilisateur (USR-YYYY-XXXXX)
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    creator_id UUID NOT NULL, -- ID de l'agent ou sous-agent créateur
    creator_type VARCHAR(20) NOT NULL CHECK (creator_type IN ('agent', 'sub_agent')),
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255),
    phone VARCHAR(20),
    invitation_token UUID UNIQUE DEFAULT uuid_generate_v4(),
    invitation_link TEXT,
    status user_status_agent DEFAULT 'invited',
    device_type device_type,
    activated_at TIMESTAMP WITH TIME ZONE,
    last_login TIMESTAMP WITH TIME ZONE,
    total_revenue_generated DECIMAL(15,2) DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- Table des Commissions
-- =====================================================
CREATE TABLE public.agent_commissions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    commission_code VARCHAR(30) UNIQUE NOT NULL, -- Code unique commission (COM-YYYY-XXXXXXX)
    recipient_id UUID NOT NULL, -- ID de l'agent ou sous-agent qui reçoit
    recipient_type VARCHAR(20) NOT NULL CHECK (recipient_type IN ('agent', 'sub_agent')),
    source_user_id UUID REFERENCES public.agent_created_users(id) ON DELETE CASCADE,
    source_transaction_id UUID, -- Référence à la transaction source
    amount DECIMAL(15,2) NOT NULL,
    commission_rate DECIMAL(5,4) NOT NULL, -- Taux de commission appliqué
    source_type commission_source_type NOT NULL,
    calculation_details JSONB, -- Détails du calcul pour audit
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'paid', 'cancelled')),
    paid_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- Table des Transactions liées aux agents
-- =====================================================
CREATE TABLE public.agent_transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    transaction_code VARCHAR(30) UNIQUE NOT NULL, -- Code unique transaction (TXN-YYYY-XXXXXXX)
    user_id UUID REFERENCES public.agent_created_users(id) ON DELETE CASCADE,
    amount DECIMAL(15,2) NOT NULL, -- Montant de la transaction
    net_revenue DECIMAL(15,2) NOT NULL, -- Revenu net après frais
    commission_base DECIMAL(15,2) NOT NULL, -- Base de calcul des commissions
    transaction_type VARCHAR(50) NOT NULL,
    metadata JSONB,
    processed_for_commissions BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- Table des Paramètres de Commission (configurables par PDG)
-- =====================================================
CREATE TABLE public.commission_settings (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    setting_key VARCHAR(50) UNIQUE NOT NULL,
    setting_value DECIMAL(10,6) NOT NULL,
    description TEXT,
    updated_by UUID REFERENCES public.pdg_management(id),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Insérer les paramètres par défaut
INSERT INTO public.commission_settings (setting_key, setting_value, description) VALUES
('base_user_commission', 0.200000, 'Commission de base par utilisateur (20% par défaut)'),
('parent_share_ratio', 0.500000, 'Ratio de partage avec l''agent parent (50% par défaut)'),
('min_commission_amount', 1.000000, 'Montant minimum de commission'),
('max_commission_rate', 0.500000, 'Taux maximum de commission (50%)');

-- =====================================================
-- Table d'Audit des Actions
-- =====================================================
CREATE TABLE public.agent_audit_log (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    actor_id UUID NOT NULL, -- Qui a fait l'action
    actor_type VARCHAR(20) NOT NULL CHECK (actor_type IN ('pdg', 'agent', 'sub_agent')),
    action VARCHAR(100) NOT NULL,
    target_id UUID, -- Sur qui/quoi l'action a été faite
    target_type VARCHAR(50),
    details JSONB,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- FONCTIONS POUR GÉNÉRATION DE CODES UNIQUES
-- =====================================================

-- Fonction pour générer un code agent unique
CREATE OR REPLACE FUNCTION generate_agent_code()
RETURNS TEXT AS $$
DECLARE
    new_code TEXT;
    year_part TEXT;
    counter INTEGER;
BEGIN
    year_part := EXTRACT(YEAR FROM NOW())::TEXT;
    
    -- Trouver le prochain numéro disponible
    SELECT COALESCE(MAX(CAST(SUBSTRING(agent_code FROM 10) AS INTEGER)), 0) + 1
    INTO counter
    FROM public.agents_management
    WHERE agent_code LIKE 'AGT-' || year_part || '-%';
    
    new_code := 'AGT-' || year_part || '-' || LPAD(counter::TEXT, 5, '0');
    
    RETURN new_code;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour générer un code sous-agent unique
CREATE OR REPLACE FUNCTION generate_sub_agent_code()
RETURNS TEXT AS $$
DECLARE
    new_code TEXT;
    year_part TEXT;
    counter INTEGER;
BEGIN
    year_part := EXTRACT(YEAR FROM NOW())::TEXT;
    
    SELECT COALESCE(MAX(CAST(SUBSTRING(sub_agent_code FROM 10) AS INTEGER)), 0) + 1
    INTO counter
    FROM public.sub_agents_management
    WHERE sub_agent_code LIKE 'SUB-' || year_part || '-%';
    
    new_code := 'SUB-' || year_part || '-' || LPAD(counter::TEXT, 5, '0');
    
    RETURN new_code;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour générer un code utilisateur unique
CREATE OR REPLACE FUNCTION generate_user_code()
RETURNS TEXT AS $$
DECLARE
    new_code TEXT;
    year_part TEXT;
    counter INTEGER;
BEGIN
    year_part := EXTRACT(YEAR FROM NOW())::TEXT;
    
    SELECT COALESCE(MAX(CAST(SUBSTRING(user_code FROM 10) AS INTEGER)), 0) + 1
    INTO counter
    FROM public.agent_created_users
    WHERE user_code LIKE 'USR-' || year_part || '-%';
    
    new_code := 'USR-' || year_part || '-' || LPAD(counter::TEXT, 5, '0');
    
    RETURN new_code;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- FONCTIONS DE CALCUL DES COMMISSIONS
-- =====================================================

CREATE OR REPLACE FUNCTION calculate_and_distribute_commissions(
    p_user_id UUID,
    p_transaction_amount DECIMAL,
    p_net_revenue DECIMAL
)
RETURNS JSONB AS $$
DECLARE
    user_record RECORD;
    agent_record RECORD;
    sub_agent_record RECORD;
    base_commission_rate DECIMAL;
    parent_share_ratio DECIMAL;
    total_commission DECIMAL;
    agent_commission DECIMAL;
    sub_agent_commission DECIMAL;
    result JSONB := '[]'::JSONB;
    commission_id UUID;
BEGIN
    -- Récupérer l'utilisateur
    SELECT * INTO user_record FROM public.agent_created_users WHERE id = p_user_id;
    IF NOT FOUND THEN
        RETURN '{"error": "User not found"}'::JSONB;
    END IF;

    -- Récupérer les paramètres de commission
    SELECT setting_value INTO base_commission_rate 
    FROM public.commission_settings 
    WHERE setting_key = 'base_user_commission';
    
    SELECT setting_value INTO parent_share_ratio 
    FROM public.commission_settings 
    WHERE setting_key = 'parent_share_ratio';

    total_commission := p_net_revenue * base_commission_rate;

    IF user_record.creator_type = 'agent' THEN
        -- Utilisateur créé par un agent direct
        SELECT * INTO agent_record FROM public.agents_management WHERE id = user_record.creator_id;
        
        commission_id := uuid_generate_v4();
        INSERT INTO public.agent_commissions (
            id, commission_code, recipient_id, recipient_type, source_user_id,
            amount, commission_rate, source_type, calculation_details
        ) VALUES (
            commission_id,
            'COM-' || EXTRACT(YEAR FROM NOW()) || '-' || LPAD((EXTRACT(EPOCH FROM NOW())::BIGINT % 10000000)::TEXT, 7, '0'),
            user_record.creator_id,
            'agent',
            p_user_id,
            total_commission,
            base_commission_rate,
            'user',
            jsonb_build_object(
                'base_rate', base_commission_rate,
                'net_revenue', p_net_revenue,
                'calculation_type', 'direct_agent'
            )
        );

        result := jsonb_build_array(
            jsonb_build_object(
                'recipient_id', user_record.creator_id,
                'recipient_type', 'agent',
                'amount', total_commission,
                'commission_id', commission_id
            )
        );

    ELSIF user_record.creator_type = 'sub_agent' THEN
        -- Utilisateur créé par un sous-agent
        SELECT * INTO sub_agent_record FROM public.sub_agents_management WHERE id = user_record.creator_id;
        SELECT * INTO agent_record FROM public.agents_management WHERE id = sub_agent_record.parent_agent_id;

        sub_agent_commission := total_commission * (1 - parent_share_ratio);
        agent_commission := total_commission * parent_share_ratio;

        -- Commission pour le sous-agent
        commission_id := uuid_generate_v4();
        INSERT INTO public.agent_commissions (
            id, commission_code, recipient_id, recipient_type, source_user_id,
            amount, commission_rate, source_type, calculation_details
        ) VALUES (
            commission_id,
            'COM-' || EXTRACT(YEAR FROM NOW()) || '-' || LPAD((EXTRACT(EPOCH FROM NOW())::BIGINT % 10000000)::TEXT, 7, '0'),
            user_record.creator_id,
            'sub_agent',
            p_user_id,
            sub_agent_commission,
            base_commission_rate * (1 - parent_share_ratio),
            'user',
            jsonb_build_object(
                'base_rate', base_commission_rate,
                'sub_agent_share', (1 - parent_share_ratio),
                'net_revenue', p_net_revenue,
                'calculation_type', 'sub_agent_split'
            )
        );

        result := jsonb_build_array(
            jsonb_build_object(
                'recipient_id', user_record.creator_id,
                'recipient_type', 'sub_agent',
                'amount', sub_agent_commission,
                'commission_id', commission_id
            )
        );

        -- Commission pour l'agent parent
        commission_id := uuid_generate_v4();
        INSERT INTO public.agent_commissions (
            id, commission_code, recipient_id, recipient_type, source_user_id,
            amount, commission_rate, source_type, calculation_details
        ) VALUES (
            commission_id,
            'COM-' || EXTRACT(YEAR FROM NOW()) || '-' || LPAD((EXTRACT(EPOCH FROM NOW())::BIGINT % 10000001)::TEXT, 7, '0'),
            sub_agent_record.parent_agent_id,
            'agent',
            p_user_id,
            agent_commission,
            base_commission_rate * parent_share_ratio,
            'sub_agent_user',
            jsonb_build_object(
                'base_rate', base_commission_rate,
                'parent_share', parent_share_ratio,
                'net_revenue', p_net_revenue,
                'calculation_type', 'parent_agent_split'
            )
        );

        result := result || jsonb_build_array(
            jsonb_build_object(
                'recipient_id', sub_agent_record.parent_agent_id,
                'recipient_type', 'agent',
                'amount', agent_commission,
                'commission_id', commission_id
            )
        );
    END IF;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- TRIGGERS POUR CODES AUTOMATIQUES
-- =====================================================

-- Trigger pour générer automatiquement les codes agents
CREATE OR REPLACE FUNCTION set_agent_code()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.agent_code IS NULL OR NEW.agent_code = '' THEN
        NEW.agent_code := generate_agent_code();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_set_agent_code
    BEFORE INSERT ON public.agents_management
    FOR EACH ROW
    EXECUTE FUNCTION set_agent_code();

-- Trigger pour générer automatiquement les codes sous-agents
CREATE OR REPLACE FUNCTION set_sub_agent_code()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.sub_agent_code IS NULL OR NEW.sub_agent_code = '' THEN
        NEW.sub_agent_code := generate_sub_agent_code();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_set_sub_agent_code
    BEFORE INSERT ON public.sub_agents_management
    FOR EACH ROW
    EXECUTE FUNCTION set_sub_agent_code();

-- Trigger pour générer automatiquement les codes utilisateurs
CREATE OR REPLACE FUNCTION set_user_code()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.user_code IS NULL OR NEW.user_code = '' THEN
        NEW.user_code := generate_user_code();
    END IF;
    
    -- Générer le lien d'invitation
    IF NEW.invitation_link IS NULL OR NEW.invitation_link = '' THEN
        NEW.invitation_link := 'https://224solutions.app/invite/' || NEW.invitation_token::TEXT;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_set_user_code
    BEFORE INSERT ON public.agent_created_users
    FOR EACH ROW
    EXECUTE FUNCTION set_user_code();

-- =====================================================
-- ROW LEVEL SECURITY (RLS)
-- =====================================================

-- Activer RLS sur toutes les tables
ALTER TABLE public.pdg_management ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agents_management ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sub_agents_management ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_created_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_commissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commission_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_audit_log ENABLE ROW LEVEL SECURITY;

-- Politiques RLS pour PDG (accès total)
CREATE POLICY "PDG can access all data" ON public.pdg_management
    FOR ALL USING (auth.uid() = user_id);

CREATE POLICY "PDG can manage agents" ON public.agents_management
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.pdg_management 
            WHERE user_id = auth.uid() AND is_active = true
        )
    );

-- Politiques RLS pour Agents
CREATE POLICY "Agents can access their data" ON public.agents_management
    FOR ALL USING (auth.uid() = user_id);

CREATE POLICY "Agents can manage their sub-agents" ON public.sub_agents_management
    FOR ALL USING (
        parent_agent_id IN (
            SELECT id FROM public.agents_management WHERE user_id = auth.uid()
        )
    );

-- Politiques RLS pour les utilisateurs créés
CREATE POLICY "Creators can access their users" ON public.agent_created_users
    FOR ALL USING (
        creator_id IN (
            SELECT id FROM public.agents_management WHERE user_id = auth.uid()
            UNION
            SELECT id FROM public.sub_agents_management WHERE user_id = auth.uid()
        )
    );

-- Index pour optimiser les performances
CREATE INDEX idx_agents_management_user_id ON public.agents_management(user_id);
CREATE INDEX idx_agents_management_pdg_id ON public.agents_management(pdg_id);
CREATE INDEX idx_sub_agents_management_parent_agent_id ON public.sub_agents_management(parent_agent_id);
CREATE INDEX idx_agent_created_users_creator_id ON public.agent_created_users(creator_id);
CREATE INDEX idx_agent_commissions_recipient_id ON public.agent_commissions(recipient_id);
CREATE INDEX idx_agent_transactions_user_id ON public.agent_transactions(user_id);

-- Commentaires pour documentation
COMMENT ON TABLE public.agents_management IS 'Table des agents principaux créés par le PDG';
COMMENT ON TABLE public.sub_agents_management IS 'Table des sous-agents créés par les agents';
COMMENT ON TABLE public.agent_created_users IS 'Table des utilisateurs créés par agents/sous-agents';
COMMENT ON TABLE public.agent_commissions IS 'Table des commissions calculées automatiquement';
COMMENT ON TABLE public.commission_settings IS 'Paramètres configurables des commissions par le PDG';

-- Fin de la migration
SELECT 'Migration agent management system completed successfully' as status;
