-- =====================================================
-- SYSTÈME BUREAU SYNDICAT ULTRA PROFESSIONNEL - 224SOLUTIONS
-- =====================================================
-- Date: 30 septembre 2025
-- Version: 1.0.0
-- Description: Système complet de gestion syndicale avec gouvernance démocratique

-- =====================================================
-- 1. BUREAUX SYNDICAUX
-- =====================================================

-- Table principale des bureaux syndicaux
CREATE TABLE IF NOT EXISTS syndicate_bureaus (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bureau_code VARCHAR(20) UNIQUE NOT NULL, -- Format: SYN-YYYY-XXXXX
    prefecture VARCHAR(100) NOT NULL,
    commune VARCHAR(100) NOT NULL,
    full_location TEXT NOT NULL, -- Prefecture + Commune
    
    -- Président du syndicat
    president_name VARCHAR(200) NOT NULL,
    president_email VARCHAR(255) NOT NULL UNIQUE,
    president_phone VARCHAR(20),
    president_user_id UUID REFERENCES auth.users(id),
    
    -- Lien permanent et accès
    permanent_link VARCHAR(500) UNIQUE NOT NULL,
    access_token VARCHAR(100) UNIQUE NOT NULL,
    link_sent_at TIMESTAMPTZ,
    link_accessed_at TIMESTAMPTZ,
    
    -- Statut et validation
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'suspended', 'dissolved')),
    validated_by UUID REFERENCES auth.users(id),
    validated_at TIMESTAMPTZ,
    
    -- Statistiques
    total_members INTEGER DEFAULT 0,
    active_members INTEGER DEFAULT 0,
    total_vehicles INTEGER DEFAULT 0,
    total_cotisations DECIMAL(15, 2) DEFAULT 0,
    
    -- Métadonnées
    created_by UUID NOT NULL REFERENCES auth.users(id), -- PDG qui a créé
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 2. MEMBRES DU SYNDICAT
-- =====================================================

-- Table des membres du syndicat
CREATE TABLE IF NOT EXISTS syndicate_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bureau_id UUID NOT NULL REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    user_id UUID REFERENCES auth.users(id), -- Lié au compte utilisateur si existant
    
    -- Informations personnelles
    member_id VARCHAR(20) UNIQUE NOT NULL, -- Format: MBR-YYYY-XXXXX
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    email VARCHAR(255),
    phone VARCHAR(20) NOT NULL,
    address TEXT,
    
    -- Documents KYC
    cni_number VARCHAR(50) UNIQUE,
    cni_front_url TEXT,
    cni_back_url TEXT,
    photo_url TEXT,
    
    -- Rôle et permissions
    member_type VARCHAR(30) NOT NULL CHECK (member_type IN ('driver', 'delivery', 'vendor', 'bureau_member')),
    internal_role VARCHAR(50), -- président, secrétaire, trésorier, etc.
    permissions JSONB DEFAULT '[]',
    
    -- Statut
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('pending', 'active', 'suspended', 'retired', 'expelled')),
    suspension_reason TEXT,
    suspended_until TIMESTAMPTZ,
    
    -- Wallet automatique
    wallet_id UUID,
    wallet_activated BOOLEAN DEFAULT false,
    wallet_activated_at TIMESTAMPTZ,
    
    -- Cotisations
    cotisation_status VARCHAR(20) DEFAULT 'pending' CHECK (cotisation_status IN ('pending', 'current', 'overdue', 'exempt')),
    last_cotisation_date DATE,
    next_cotisation_due DATE,
    
    -- Métadonnées
    added_by UUID NOT NULL REFERENCES syndicate_members(id), -- Président qui a ajouté
    joined_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 3. VÉHICULES ET BADGES
-- =====================================================

-- Table des véhicules
CREATE TABLE IF NOT EXISTS syndicate_vehicles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    member_id UUID NOT NULL REFERENCES syndicate_members(id) ON DELETE CASCADE,
    bureau_id UUID NOT NULL REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    
    -- Informations véhicule
    serial_number VARCHAR(100) UNIQUE NOT NULL, -- Numéro de série unique
    license_plate VARCHAR(20) NOT NULL,
    vehicle_type VARCHAR(30) DEFAULT 'motorcycle' CHECK (vehicle_type IN ('motorcycle', 'tricycle', 'car')),
    brand VARCHAR(50),
    model VARCHAR(50),
    year INTEGER,
    color VARCHAR(30),
    
    -- Documents
    registration_document_url TEXT, -- Carte grise
    insurance_document_url TEXT,
    technical_control_url TEXT,
    
    -- Badge numérique
    digital_badge_id VARCHAR(50) UNIQUE NOT NULL,
    qr_code_data TEXT NOT NULL, -- Données du QR code
    badge_generated_at TIMESTAMPTZ DEFAULT NOW(),
    badge_last_updated TIMESTAMPTZ DEFAULT NOW(),
    
    -- Statut
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'maintenance', 'retired')),
    verified BOOLEAN DEFAULT false,
    verified_by UUID REFERENCES auth.users(id),
    verified_at TIMESTAMPTZ,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 4. CAISSE ET COTISATIONS
-- =====================================================

-- Configuration des cotisations
CREATE TABLE IF NOT EXISTS syndicate_cotisation_config (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bureau_id UUID NOT NULL REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    
    -- Montants
    monthly_amount DECIMAL(10, 2) NOT NULL DEFAULT 5000, -- 5000 FCFA par défaut
    annual_amount DECIMAL(10, 2),
    registration_fee DECIMAL(10, 2) DEFAULT 10000,
    
    -- Périodes
    payment_frequency VARCHAR(20) DEFAULT 'monthly' CHECK (payment_frequency IN ('weekly', 'monthly', 'quarterly', 'annual')),
    grace_period_days INTEGER DEFAULT 7,
    
    -- Pénalités
    late_fee_amount DECIMAL(10, 2) DEFAULT 1000,
    late_fee_percentage DECIMAL(5, 2) DEFAULT 10.0,
    
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Transactions de cotisations
CREATE TABLE IF NOT EXISTS syndicate_cotisations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bureau_id UUID NOT NULL REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    member_id UUID NOT NULL REFERENCES syndicate_members(id) ON DELETE CASCADE,
    
    -- Détails de la cotisation
    cotisation_type VARCHAR(30) NOT NULL CHECK (cotisation_type IN ('registration', 'monthly', 'quarterly', 'annual', 'special', 'fine')),
    amount DECIMAL(10, 2) NOT NULL,
    currency VARCHAR(5) DEFAULT 'FCFA',
    
    -- Période couverte
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    due_date DATE NOT NULL,
    
    -- Paiement
    payment_method VARCHAR(30) CHECK (payment_method IN ('mobile_money', 'card', 'wallet_224', 'cash', 'bank_transfer')),
    payment_reference VARCHAR(100),
    payment_status VARCHAR(20) DEFAULT 'pending' CHECK (payment_status IN ('pending', 'paid', 'overdue', 'cancelled', 'refunded')),
    paid_at TIMESTAMPTZ,
    
    -- Pénalités
    late_fee DECIMAL(10, 2) DEFAULT 0,
    total_amount DECIMAL(10, 2) NOT NULL, -- amount + late_fee
    
    -- Métadonnées
    notes TEXT,
    processed_by UUID REFERENCES syndicate_members(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Caisse syndicale
CREATE TABLE IF NOT EXISTS syndicate_treasury (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bureau_id UUID NOT NULL REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    
    -- Transaction
    transaction_type VARCHAR(30) NOT NULL CHECK (transaction_type IN ('income', 'expense', 'transfer', 'adjustment')),
    category VARCHAR(50) NOT NULL, -- cotisation, aide_solidaire, frais_fonctionnement, etc.
    amount DECIMAL(12, 2) NOT NULL,
    currency VARCHAR(5) DEFAULT 'FCFA',
    
    -- Description
    title VARCHAR(200) NOT NULL,
    description TEXT,
    
    -- Références
    reference_type VARCHAR(30), -- cotisation, election, emergency_aid, etc.
    reference_id UUID,
    
    -- Validation
    approved_by UUID REFERENCES syndicate_members(id),
    approved_at TIMESTAMPTZ,
    
    -- Métadonnées
    created_by UUID NOT NULL REFERENCES syndicate_members(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 5. TICKETS ROUTIERS
-- =====================================================

-- Configuration des tickets routiers
CREATE TABLE IF NOT EXISTS road_ticket_config (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bureau_id UUID NOT NULL REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    
    -- Tarification
    daily_ticket_price DECIMAL(8, 2) DEFAULT 500,
    weekly_ticket_price DECIMAL(8, 2) DEFAULT 3000,
    monthly_ticket_price DECIMAL(8, 2) DEFAULT 10000,
    
    -- Validité
    ticket_validity_hours INTEGER DEFAULT 24, -- Pour ticket journalier
    
    -- Configuration
    auto_generate BOOLEAN DEFAULT false,
    require_approval BOOLEAN DEFAULT true,
    
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Tickets routiers
CREATE TABLE IF NOT EXISTS road_tickets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bureau_id UUID NOT NULL REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    member_id UUID NOT NULL REFERENCES syndicate_members(id) ON DELETE CASCADE,
    vehicle_id UUID NOT NULL REFERENCES syndicate_vehicles(id) ON DELETE CASCADE,
    
    -- Informations du ticket
    ticket_number VARCHAR(50) UNIQUE NOT NULL, -- Format: TKT-YYYY-XXXXXXX
    ticket_type VARCHAR(20) NOT NULL CHECK (ticket_type IN ('daily', 'weekly', 'monthly')),
    amount DECIMAL(8, 2) NOT NULL,
    
    -- Validité
    valid_from TIMESTAMPTZ NOT NULL,
    valid_until TIMESTAMPTZ NOT NULL,
    
    -- QR Code et vérification
    qr_code_data TEXT NOT NULL,
    verification_code VARCHAR(20) UNIQUE NOT NULL,
    
    -- Statut
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('pending', 'active', 'expired', 'cancelled', 'used')),
    
    -- Paiement
    payment_method VARCHAR(30),
    payment_reference VARCHAR(100),
    payment_status VARCHAR(20) DEFAULT 'pending',
    paid_at TIMESTAMPTZ,
    
    -- Utilisation
    used_at TIMESTAMPTZ,
    verified_by VARCHAR(100), -- Autorité qui a vérifié
    verification_location JSONB, -- Coordonnées GPS
    
    -- Métadonnées
    generated_by UUID REFERENCES syndicate_members(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 6. COMMUNICATION ET MESSAGERIE
-- =====================================================

-- Annonces et communiqués
CREATE TABLE IF NOT EXISTS syndicate_announcements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bureau_id UUID NOT NULL REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    
    -- Contenu
    title VARCHAR(200) NOT NULL,
    content TEXT NOT NULL,
    announcement_type VARCHAR(30) DEFAULT 'general' CHECK (announcement_type IN ('general', 'urgent', 'meeting', 'election', 'cotisation', 'regulation')),
    
    -- Ciblage
    target_audience VARCHAR(30) DEFAULT 'all' CHECK (target_audience IN ('all', 'drivers', 'delivery', 'vendors', 'bureau_members')),
    target_members UUID[], -- IDs spécifiques si ciblage précis
    
    -- Publication
    published BOOLEAN DEFAULT false,
    published_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    
    -- Statistiques
    views_count INTEGER DEFAULT 0,
    
    -- Métadonnées
    created_by UUID NOT NULL REFERENCES syndicate_members(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Messagerie interne
CREATE TABLE IF NOT EXISTS syndicate_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bureau_id UUID NOT NULL REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    
    -- Participants
    sender_id UUID NOT NULL REFERENCES syndicate_members(id),
    recipient_id UUID REFERENCES syndicate_members(id), -- NULL pour messages de groupe
    
    -- Contenu
    subject VARCHAR(200),
    content TEXT NOT NULL,
    message_type VARCHAR(20) DEFAULT 'private' CHECK (message_type IN ('private', 'group', 'broadcast')),
    
    -- Pièces jointes
    attachments JSONB DEFAULT '[]',
    
    -- Statut
    is_read BOOLEAN DEFAULT false,
    read_at TIMESTAMPTZ,
    is_archived BOOLEAN DEFAULT false,
    
    -- Réponse
    reply_to UUID REFERENCES syndicate_messages(id),
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Revendications
CREATE TABLE IF NOT EXISTS syndicate_claims (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bureau_id UUID NOT NULL REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    
    -- Contenu
    title VARCHAR(200) NOT NULL,
    description TEXT NOT NULL,
    claim_type VARCHAR(30) NOT NULL CHECK (claim_type IN ('salary', 'working_conditions', 'safety', 'equipment', 'regulation', 'other')),
    priority VARCHAR(20) DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high', 'urgent')),
    
    -- Statut
    status VARCHAR(30) DEFAULT 'submitted' CHECK (status IN ('draft', 'submitted', 'under_review', 'negotiating', 'accepted', 'rejected', 'closed')),
    
    -- Suivi
    submitted_to VARCHAR(100), -- Autorité/entreprise concernée
    response_expected_by DATE,
    response_received_at TIMESTAMPTZ,
    response_content TEXT,
    
    -- Support
    supporters_count INTEGER DEFAULT 0,
    supporters_ids UUID[], -- Membres qui soutiennent
    
    -- Métadonnées
    submitted_by UUID NOT NULL REFERENCES syndicate_members(id),
    handled_by UUID REFERENCES syndicate_members(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 7. ÉLECTIONS ET GOUVERNANCE
-- =====================================================

-- Élections
CREATE TABLE IF NOT EXISTS syndicate_elections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bureau_id UUID NOT NULL REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    
    -- Informations générales
    title VARCHAR(200) NOT NULL,
    description TEXT,
    election_type VARCHAR(30) NOT NULL CHECK (election_type IN ('president', 'bureau_member', 'representative', 'referendum')),
    
    -- Calendrier
    registration_start TIMESTAMPTZ NOT NULL,
    registration_end TIMESTAMPTZ NOT NULL,
    voting_start TIMESTAMPTZ NOT NULL,
    voting_end TIMESTAMPTZ NOT NULL,
    
    -- Configuration
    max_candidates INTEGER DEFAULT 10,
    min_votes_required INTEGER DEFAULT 1,
    require_majority BOOLEAN DEFAULT true,
    allow_abstention BOOLEAN DEFAULT true,
    
    -- Statut
    status VARCHAR(30) DEFAULT 'draft' CHECK (status IN ('draft', 'registration_open', 'registration_closed', 'voting_open', 'voting_closed', 'completed', 'cancelled')),
    
    -- Résultats
    total_eligible_voters INTEGER DEFAULT 0,
    total_votes_cast INTEGER DEFAULT 0,
    results_published BOOLEAN DEFAULT false,
    results_published_at TIMESTAMPTZ,
    
    -- Métadonnées
    created_by UUID NOT NULL REFERENCES syndicate_members(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Candidats aux élections
CREATE TABLE IF NOT EXISTS election_candidates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    election_id UUID NOT NULL REFERENCES syndicate_elections(id) ON DELETE CASCADE,
    member_id UUID NOT NULL REFERENCES syndicate_members(id) ON DELETE CASCADE,
    
    -- Candidature
    position VARCHAR(100) NOT NULL, -- président, secrétaire, etc.
    program TEXT, -- Programme électoral
    
    -- Validation
    approved BOOLEAN DEFAULT false,
    approved_by UUID REFERENCES syndicate_members(id),
    approved_at TIMESTAMPTZ,
    rejection_reason TEXT,
    
    -- Résultats
    votes_received INTEGER DEFAULT 0,
    vote_percentage DECIMAL(5, 2) DEFAULT 0,
    is_winner BOOLEAN DEFAULT false,
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Votes (cryptés)
CREATE TABLE IF NOT EXISTS election_votes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    election_id UUID NOT NULL REFERENCES syndicate_elections(id) ON DELETE CASCADE,
    voter_id UUID NOT NULL REFERENCES syndicate_members(id) ON DELETE CASCADE,
    
    -- Vote crypté
    encrypted_vote TEXT NOT NULL, -- Vote chiffré
    vote_hash VARCHAR(128) UNIQUE NOT NULL, -- Hash pour vérification
    
    -- Métadonnées
    voted_at TIMESTAMPTZ DEFAULT NOW(),
    ip_address INET,
    user_agent TEXT,
    
    UNIQUE(election_id, voter_id) -- Un vote par personne par élection
);

-- =====================================================
-- 8. SYSTÈME D'URGENCE SOS
-- =====================================================

-- Alertes SOS
CREATE TABLE IF NOT EXISTS syndicate_sos_alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bureau_id UUID NOT NULL REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    member_id UUID NOT NULL REFERENCES syndicate_members(id) ON DELETE CASCADE,
    vehicle_id UUID REFERENCES syndicate_vehicles(id),
    
    -- Informations de l'alerte
    alert_type VARCHAR(30) DEFAULT 'emergency' CHECK (alert_type IN ('emergency', 'accident', 'theft', 'harassment', 'breakdown')),
    severity VARCHAR(20) DEFAULT 'high' CHECK (severity IN ('low', 'medium', 'high', 'critical')),
    
    -- Localisation
    latitude DECIMAL(10, 8) NOT NULL,
    longitude DECIMAL(11, 8) NOT NULL,
    location_accuracy DECIMAL(8, 2),
    address TEXT,
    
    -- Détails
    description TEXT,
    emergency_contact VARCHAR(20), -- Numéro à contacter
    
    -- Statut
    status VARCHAR(30) DEFAULT 'active' CHECK (status IN ('active', 'acknowledged', 'responding', 'resolved', 'false_alarm')),
    
    -- Réponse
    acknowledged_by UUID REFERENCES syndicate_members(id),
    acknowledged_at TIMESTAMPTZ,
    responders UUID[], -- IDs des personnes qui répondent
    response_notes TEXT,
    resolved_at TIMESTAMPTZ,
    
    -- Notifications envoyées
    pdg_notified BOOLEAN DEFAULT false,
    pdg_notified_at TIMESTAMPTZ,
    bureau_notified BOOLEAN DEFAULT false,
    bureau_notified_at TIMESTAMPTZ,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 9. AUDIT ET LOGS
-- =====================================================

-- Logs d'audit pour traçabilité complète
CREATE TABLE IF NOT EXISTS syndicate_audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bureau_id UUID REFERENCES syndicate_bureaus(id) ON DELETE CASCADE,
    
    -- Acteur
    actor_id UUID REFERENCES syndicate_members(id),
    actor_type VARCHAR(30) NOT NULL, -- member, president, pdg, system
    actor_name VARCHAR(200),
    
    -- Action
    action VARCHAR(50) NOT NULL, -- create, update, delete, vote, payment, etc.
    resource_type VARCHAR(50) NOT NULL, -- member, vehicle, cotisation, election, etc.
    resource_id UUID,
    
    -- Détails
    description TEXT NOT NULL,
    old_values JSONB,
    new_values JSONB,
    
    -- Contexte
    ip_address INET,
    user_agent TEXT,
    session_id VARCHAR(100),
    
    -- Métadonnées
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 10. FONCTIONS UTILITAIRES
-- =====================================================

-- Génération du code bureau
CREATE OR REPLACE FUNCTION generate_bureau_code()
RETURNS TEXT AS $$
DECLARE
    new_code TEXT;
    counter INTEGER;
BEGIN
    SELECT COALESCE(MAX(CAST(SUBSTRING(bureau_code FROM 10) AS INTEGER)), 0) + 1
    INTO counter
    FROM syndicate_bureaus
    WHERE bureau_code LIKE 'SYN-' || TO_CHAR(CURRENT_DATE, 'YYYY') || '-%';
    
    new_code := 'SYN-' || TO_CHAR(CURRENT_DATE, 'YYYY') || '-' || LPAD(counter::TEXT, 5, '0');
    RETURN new_code;
END;
$$ LANGUAGE plpgsql;

-- Génération de l'ID membre
CREATE OR REPLACE FUNCTION generate_member_id()
RETURNS TEXT AS $$
DECLARE
    new_id TEXT;
    counter INTEGER;
BEGIN
    SELECT COALESCE(MAX(CAST(SUBSTRING(member_id FROM 10) AS INTEGER)), 0) + 1
    INTO counter
    FROM syndicate_members
    WHERE member_id LIKE 'MBR-' || TO_CHAR(CURRENT_DATE, 'YYYY') || '-%';
    
    new_id := 'MBR-' || TO_CHAR(CURRENT_DATE, 'YYYY') || '-' || LPAD(counter::TEXT, 5, '0');
    RETURN new_id;
END;
$$ LANGUAGE plpgsql;

-- Génération du numéro de ticket
CREATE OR REPLACE FUNCTION generate_ticket_number()
RETURNS TEXT AS $$
DECLARE
    new_number TEXT;
    counter INTEGER;
BEGIN
    SELECT COALESCE(MAX(CAST(SUBSTRING(ticket_number FROM 10) AS INTEGER)), 0) + 1
    INTO counter
    FROM road_tickets
    WHERE ticket_number LIKE 'TKT-' || TO_CHAR(CURRENT_DATE, 'YYYY') || '-%';
    
    new_number := 'TKT-' || TO_CHAR(CURRENT_DATE, 'YYYY') || '-' || LPAD(counter::TEXT, 7, '0');
    RETURN new_number;
END;
$$ LANGUAGE plpgsql;

-- Génération du badge numérique
CREATE OR REPLACE FUNCTION generate_digital_badge_id()
RETURNS TEXT AS $$
BEGIN
    RETURN 'BDG-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || UPPER(SUBSTRING(gen_random_uuid()::TEXT FROM 1 FOR 8));
END;
$$ LANGUAGE plpgsql;

-- Calcul du solde de caisse
CREATE OR REPLACE FUNCTION calculate_treasury_balance(bureau_uuid UUID)
RETURNS DECIMAL AS $$
DECLARE
    total_income DECIMAL := 0;
    total_expense DECIMAL := 0;
    balance DECIMAL := 0;
BEGIN
    -- Revenus
    SELECT COALESCE(SUM(amount), 0) INTO total_income
    FROM syndicate_treasury
    WHERE bureau_id = bureau_uuid AND transaction_type = 'income';
    
    -- Dépenses
    SELECT COALESCE(SUM(amount), 0) INTO total_expense
    FROM syndicate_treasury
    WHERE bureau_id = bureau_uuid AND transaction_type = 'expense';
    
    balance := total_income - total_expense;
    RETURN balance;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 11. TRIGGERS AUTOMATIQUES
-- =====================================================

-- Trigger pour générer automatiquement les codes
CREATE OR REPLACE FUNCTION set_bureau_code()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.bureau_code IS NULL THEN
        NEW.bureau_code := generate_bureau_code();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_bureau_code_trigger
    BEFORE INSERT ON syndicate_bureaus
    FOR EACH ROW EXECUTE FUNCTION set_bureau_code();

CREATE OR REPLACE FUNCTION set_member_id()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.member_id IS NULL THEN
        NEW.member_id := generate_member_id();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_member_id_trigger
    BEFORE INSERT ON syndicate_members
    FOR EACH ROW EXECUTE FUNCTION set_member_id();

CREATE OR REPLACE FUNCTION set_ticket_number()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.ticket_number IS NULL THEN
        NEW.ticket_number := generate_ticket_number();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_ticket_number_trigger
    BEFORE INSERT ON road_tickets
    FOR EACH ROW EXECUTE FUNCTION set_ticket_number();

-- Trigger pour l'audit automatique
CREATE OR REPLACE FUNCTION log_syndicate_audit()
RETURNS TRIGGER AS $$
DECLARE
    action_type TEXT;
    bureau_uuid UUID;
BEGIN
    -- Déterminer le type d'action
    IF TG_OP = 'INSERT' THEN
        action_type := 'create';
    ELSIF TG_OP = 'UPDATE' THEN
        action_type := 'update';
    ELSIF TG_OP = 'DELETE' THEN
        action_type := 'delete';
    END IF;
    
    -- Obtenir l'ID du bureau selon la table
    IF TG_TABLE_NAME = 'syndicate_bureaus' THEN
        bureau_uuid := COALESCE(NEW.id, OLD.id);
    ELSE
        bureau_uuid := COALESCE(NEW.bureau_id, OLD.bureau_id);
    END IF;
    
    -- Insérer le log d'audit
    INSERT INTO syndicate_audit_logs (
        bureau_id,
        actor_type,
        action,
        resource_type,
        resource_id,
        description,
        old_values,
        new_values
    ) VALUES (
        bureau_uuid,
        'system',
        action_type,
        TG_TABLE_NAME,
        COALESCE(NEW.id, OLD.id),
        action_type || ' on ' || TG_TABLE_NAME,
        CASE WHEN TG_OP != 'INSERT' THEN row_to_json(OLD) ELSE NULL END,
        CASE WHEN TG_OP != 'DELETE' THEN row_to_json(NEW) ELSE NULL END
    );
    
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- Appliquer l'audit sur les tables principales
CREATE TRIGGER audit_syndicate_bureaus AFTER INSERT OR UPDATE OR DELETE ON syndicate_bureaus FOR EACH ROW EXECUTE FUNCTION log_syndicate_audit();
CREATE TRIGGER audit_syndicate_members AFTER INSERT OR UPDATE OR DELETE ON syndicate_members FOR EACH ROW EXECUTE FUNCTION log_syndicate_audit();
CREATE TRIGGER audit_syndicate_vehicles AFTER INSERT OR UPDATE OR DELETE ON syndicate_vehicles FOR EACH ROW EXECUTE FUNCTION log_syndicate_audit();
CREATE TRIGGER audit_syndicate_cotisations AFTER INSERT OR UPDATE OR DELETE ON syndicate_cotisations FOR EACH ROW EXECUTE FUNCTION log_syndicate_audit();
CREATE TRIGGER audit_election_votes AFTER INSERT ON election_votes FOR EACH ROW EXECUTE FUNCTION log_syndicate_audit();

-- =====================================================
-- 12. INDICES POUR PERFORMANCE
-- =====================================================

-- Indices principaux
CREATE INDEX IF NOT EXISTS idx_syndicate_bureaus_status ON syndicate_bureaus(status);
CREATE INDEX IF NOT EXISTS idx_syndicate_bureaus_president ON syndicate_bureaus(president_email);
CREATE INDEX IF NOT EXISTS idx_syndicate_members_bureau ON syndicate_members(bureau_id);
CREATE INDEX IF NOT EXISTS idx_syndicate_members_status ON syndicate_members(status);
CREATE INDEX IF NOT EXISTS idx_syndicate_members_type ON syndicate_members(member_type);
CREATE INDEX IF NOT EXISTS idx_syndicate_vehicles_serial ON syndicate_vehicles(serial_number);
CREATE INDEX IF NOT EXISTS idx_syndicate_vehicles_member ON syndicate_vehicles(member_id);
CREATE INDEX IF NOT EXISTS idx_syndicate_cotisations_member ON syndicate_cotisations(member_id);
CREATE INDEX IF NOT EXISTS idx_syndicate_cotisations_status ON syndicate_cotisations(payment_status);
CREATE INDEX IF NOT EXISTS idx_road_tickets_vehicle ON road_tickets(vehicle_id);
CREATE INDEX IF NOT EXISTS idx_road_tickets_status ON road_tickets(status);
CREATE INDEX IF NOT EXISTS idx_sos_alerts_status ON syndicate_sos_alerts(status);
CREATE INDEX IF NOT EXISTS idx_sos_alerts_location ON syndicate_sos_alerts(latitude, longitude);
CREATE INDEX IF NOT EXISTS idx_audit_logs_bureau ON syndicate_audit_logs(bureau_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created ON syndicate_audit_logs(created_at DESC);

-- =====================================================
-- 13. POLITIQUES DE SÉCURITÉ (RLS)
-- =====================================================

-- Activer RLS sur toutes les tables
ALTER TABLE syndicate_bureaus ENABLE ROW LEVEL SECURITY;
ALTER TABLE syndicate_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE syndicate_vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE syndicate_cotisations ENABLE ROW LEVEL SECURITY;
ALTER TABLE syndicate_treasury ENABLE ROW LEVEL SECURITY;
ALTER TABLE road_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE syndicate_announcements ENABLE ROW LEVEL SECURITY;
ALTER TABLE syndicate_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE syndicate_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE syndicate_elections ENABLE ROW LEVEL SECURITY;
ALTER TABLE election_candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE election_votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE syndicate_sos_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE syndicate_audit_logs ENABLE ROW LEVEL SECURITY;

-- Politiques pour PDG (accès total)
CREATE POLICY "PDG can manage all syndicate data" ON syndicate_bureaus
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM profiles 
            WHERE user_id = auth.uid() 
            AND role = 'pdg'
        )
    );

-- Politiques pour présidents (accès à leur bureau)
CREATE POLICY "Presidents can manage their bureau" ON syndicate_bureaus
    FOR ALL USING (
        auth.uid() = president_user_id OR
        EXISTS (
            SELECT 1 FROM profiles 
            WHERE user_id = auth.uid() 
            AND role = 'pdg'
        )
    );

-- Politiques pour membres (accès à leur bureau)
CREATE POLICY "Members can view their bureau data" ON syndicate_members
    FOR SELECT USING (
        bureau_id IN (
            SELECT bureau_id FROM syndicate_members 
            WHERE user_id = auth.uid()
        ) OR
        EXISTS (
            SELECT 1 FROM profiles 
            WHERE user_id = auth.uid() 
            AND role IN ('pdg', 'admin')
        )
    );

-- =====================================================
-- 14. DONNÉES INITIALES
-- =====================================================

-- Configuration par défaut des cotisations
INSERT INTO syndicate_cotisation_config (bureau_id, monthly_amount, registration_fee) 
SELECT id, 5000, 10000 FROM syndicate_bureaus 
ON CONFLICT DO NOTHING;

-- Configuration par défaut des tickets routiers
INSERT INTO road_ticket_config (bureau_id, daily_ticket_price, weekly_ticket_price, monthly_ticket_price)
SELECT id, 500, 3000, 10000 FROM syndicate_bureaus
ON CONFLICT DO NOTHING;

-- =====================================================
-- SYSTÈME BUREAU SYNDICAT CRÉÉ AVEC SUCCÈS
-- =====================================================

COMMENT ON TABLE syndicate_bureaus IS 'Bureaux syndicaux avec gestion complète des présidents et membres';
COMMENT ON TABLE syndicate_members IS 'Membres du syndicat avec KYC, rôles et permissions';
COMMENT ON TABLE syndicate_vehicles IS 'Véhicules avec badges numériques et QR codes';
COMMENT ON TABLE syndicate_cotisations IS 'Système de cotisations avec paiements multi-options';
COMMENT ON TABLE syndicate_treasury IS 'Caisse syndicale avec audit complet';
COMMENT ON TABLE road_tickets IS 'Tickets routiers avec QR codes et vérification';
COMMENT ON TABLE syndicate_elections IS 'Système d\'élections démocratiques avec votes cryptés';
COMMENT ON TABLE syndicate_sos_alerts IS 'Système d\'urgence SOS avec géolocalisation temps réel';
