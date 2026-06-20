-- ===================================================
-- MIGRATION: Système de Gestion des Dépenses Vendeurs - 224SOLUTIONS
-- Date: 2025-01-01 15:00:00
-- Description: Système complet de gestion des dépenses pour les vendeurs
-- ===================================================

-- 1. Types ENUM pour les dépenses
CREATE TYPE expense_status AS ENUM ('draft', 'pending', 'approved', 'rejected', 'paid');
CREATE TYPE expense_payment_method AS ENUM ('wallet', 'cash', 'bank_transfer', 'mobile_money', 'card');
CREATE TYPE receipt_type AS ENUM ('image', 'pdf', 'scan');

-- 2. Table des catégories de dépenses (personnalisables par vendeur)
CREATE TABLE IF NOT EXISTS expense_categories (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    vendor_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    color VARCHAR(7) DEFAULT '#3B82F6', -- Couleur hex pour l'UI
    icon VARCHAR(50) DEFAULT 'Package', -- Icône Lucide React
    budget_limit DECIMAL(15,2), -- Limite budgétaire mensuelle
    is_default BOOLEAN DEFAULT false, -- Catégories par défaut du système
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT unique_vendor_category_name UNIQUE(vendor_id, name)
);

-- 3. Table principale des dépenses
CREATE TABLE IF NOT EXISTS vendor_expenses (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    vendor_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    category_id UUID REFERENCES expense_categories(id) ON DELETE SET NULL,
    
    -- Informations de base
    title VARCHAR(200) NOT NULL,
    description TEXT,
    amount DECIMAL(15,2) NOT NULL CHECK (amount > 0),
    currency VARCHAR(3) DEFAULT 'XAF',
    expense_date DATE NOT NULL DEFAULT CURRENT_DATE,
    
    -- Informations fournisseur/bénéficiaire
    supplier_name VARCHAR(200),
    supplier_contact VARCHAR(100),
    
    -- Méthode de paiement et référence
    payment_method expense_payment_method NOT NULL DEFAULT 'cash',
    payment_reference VARCHAR(100), -- Référence transaction wallet, etc.
    wallet_transaction_id UUID REFERENCES wallet_transactions(id),
    
    -- Statut et approbation
    status expense_status DEFAULT 'pending',
    approved_by UUID REFERENCES profiles(id),
    approved_at TIMESTAMP WITH TIME ZONE,
    rejection_reason TEXT,
    
    -- Métadonnées
    tags TEXT[], -- Tags pour recherche avancée
    is_recurring BOOLEAN DEFAULT false,
    recurring_frequency VARCHAR(20), -- 'weekly', 'monthly', 'yearly'
    next_occurrence DATE,
    
    -- Audit et sécurité
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by UUID REFERENCES profiles(id),
    
    -- Index pour performance
    CONSTRAINT valid_recurring_data CHECK (
        (is_recurring = false) OR 
        (is_recurring = true AND recurring_frequency IS NOT NULL AND next_occurrence IS NOT NULL)
    )
);

-- 4. Table des justificatifs/reçus
CREATE TABLE IF NOT EXISTS expense_receipts (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    expense_id UUID NOT NULL REFERENCES vendor_expenses(id) ON DELETE CASCADE,
    
    -- Informations du fichier
    file_name VARCHAR(255) NOT NULL,
    file_path VARCHAR(500) NOT NULL, -- Chemin Supabase Storage
    file_size INTEGER, -- Taille en bytes
    file_type receipt_type NOT NULL,
    mime_type VARCHAR(100),
    
    -- OCR et analyse IA
    ocr_text TEXT, -- Texte extrait par OCR
    ocr_confidence DECIMAL(5,2), -- Confiance OCR (0-100%)
    ai_analysis JSONB, -- Analyse IA (montant détecté, date, etc.)
    
    -- Métadonnées
    uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    processed_at TIMESTAMP WITH TIME ZONE,
    is_primary BOOLEAN DEFAULT false, -- Reçu principal
    
    CONSTRAINT unique_primary_receipt_per_expense 
        EXCLUDE (expense_id WITH =) WHERE (is_primary = true)
);

-- 5. Table des budgets mensuels par catégorie
CREATE TABLE IF NOT EXISTS expense_budgets (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    vendor_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    category_id UUID REFERENCES expense_categories(id) ON DELETE CASCADE,
    
    -- Période budgétaire
    year INTEGER NOT NULL,
    month INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
    
    -- Montants budgétaires
    planned_amount DECIMAL(15,2) NOT NULL CHECK (planned_amount >= 0),
    spent_amount DECIMAL(15,2) DEFAULT 0 CHECK (spent_amount >= 0),
    remaining_amount DECIMAL(15,2) GENERATED ALWAYS AS (planned_amount - spent_amount) STORED,
    
    -- Alertes
    alert_threshold DECIMAL(5,2) DEFAULT 80.00, -- Seuil d'alerte en %
    alert_sent BOOLEAN DEFAULT false,
    
    -- Audit
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT unique_vendor_category_period UNIQUE(vendor_id, category_id, year, month)
);

-- 6. Table des analyses et insights IA
CREATE TABLE IF NOT EXISTS expense_analytics (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    vendor_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    
    -- Période d'analyse
    analysis_period VARCHAR(20) NOT NULL, -- 'daily', 'weekly', 'monthly', 'yearly'
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    
    -- Métriques calculées
    total_expenses DECIMAL(15,2) DEFAULT 0,
    total_revenue DECIMAL(15,2) DEFAULT 0, -- Depuis les ventes
    net_profit DECIMAL(15,2) GENERATED ALWAYS AS (total_revenue - total_expenses) STORED,
    profit_margin DECIMAL(5,2), -- Marge bénéficiaire en %
    
    -- Analyses par catégorie (JSON)
    category_breakdown JSONB, -- {"stock": 45000, "marketing": 12000, ...}
    trend_analysis JSONB, -- Tendances et prévisions
    anomalies JSONB, -- Dépenses anormales détectées
    recommendations JSONB, -- Recommandations IA
    
    -- Scores et indicateurs
    efficiency_score DECIMAL(5,2), -- Score d'efficacité (0-100)
    risk_score DECIMAL(5,2), -- Score de risque (0-100)
    
    -- Métadonnées
    generated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    is_current BOOLEAN DEFAULT true, -- Analyse la plus récente
    
    CONSTRAINT unique_vendor_current_period UNIQUE(vendor_id, analysis_period, is_current) 
        WHERE (is_current = true)
);

-- 7. Table des alertes et notifications
CREATE TABLE IF NOT EXISTS expense_alerts (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    vendor_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    expense_id UUID REFERENCES vendor_expenses(id) ON DELETE CASCADE,
    category_id UUID REFERENCES expense_categories(id) ON DELETE CASCADE,
    
    -- Type et contenu de l'alerte
    alert_type VARCHAR(50) NOT NULL, -- 'budget_exceeded', 'anomaly_detected', 'approval_needed', etc.
    title VARCHAR(200) NOT NULL,
    message TEXT NOT NULL,
    severity VARCHAR(20) DEFAULT 'medium', -- 'low', 'medium', 'high', 'critical'
    
    -- Statut
    is_read BOOLEAN DEFAULT false,
    is_dismissed BOOLEAN DEFAULT false,
    action_required BOOLEAN DEFAULT false,
    action_url VARCHAR(500), -- URL pour action directe
    
    -- Métadonnées
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    read_at TIMESTAMP WITH TIME ZONE,
    dismissed_at TIMESTAMP WITH TIME ZONE
);

-- ===================================================
-- INDEX POUR OPTIMISATION DES PERFORMANCES
-- ===================================================

-- Index pour les requêtes fréquentes
CREATE INDEX IF NOT EXISTS idx_vendor_expenses_vendor_date ON vendor_expenses(vendor_id, expense_date DESC);
CREATE INDEX IF NOT EXISTS idx_vendor_expenses_category ON vendor_expenses(category_id);
CREATE INDEX IF NOT EXISTS idx_vendor_expenses_status ON vendor_expenses(status);
CREATE INDEX IF NOT EXISTS idx_vendor_expenses_payment_method ON vendor_expenses(payment_method);
CREATE INDEX IF NOT EXISTS idx_expense_receipts_expense ON expense_receipts(expense_id);
CREATE INDEX IF NOT EXISTS idx_expense_budgets_vendor_period ON expense_budgets(vendor_id, year, month);
CREATE INDEX IF NOT EXISTS idx_expense_analytics_vendor_period ON expense_analytics(vendor_id, analysis_period, period_start);
CREATE INDEX IF NOT EXISTS idx_expense_alerts_vendor_unread ON expense_alerts(vendor_id, is_read) WHERE is_read = false;

-- Index pour recherche full-text
CREATE INDEX IF NOT EXISTS idx_vendor_expenses_search ON vendor_expenses USING gin(to_tsvector('french', title || ' ' || COALESCE(description, '')));

-- ===================================================
-- FONCTIONS UTILITAIRES
-- ===================================================

-- Fonction pour créer les catégories par défaut
CREATE OR REPLACE FUNCTION create_default_expense_categories(p_vendor_id UUID)
RETURNS VOID AS $$
BEGIN
    INSERT INTO expense_categories (vendor_id, name, description, color, icon, is_default) VALUES
    (p_vendor_id, 'Stock & Marchandises', 'Achat de produits pour la revente', '#10B981', 'Package', true),
    (p_vendor_id, 'Logistique & Transport', 'Frais de transport et livraison', '#3B82F6', 'Truck', true),
    (p_vendor_id, 'Marketing & Publicité', 'Promotion et communication', '#8B5CF6', 'Megaphone', true),
    (p_vendor_id, 'Salaires & Personnel', 'Rémunération des employés', '#F59E0B', 'Users', true),
    (p_vendor_id, 'Équipements & Outils', 'Matériel et équipements', '#6B7280', 'Settings', true),
    (p_vendor_id, 'Services & Abonnements', 'Services externes et abonnements', '#EC4899', 'CreditCard', true),
    (p_vendor_id, 'Frais Généraux', 'Autres dépenses diverses', '#64748B', 'MoreHorizontal', true)
    ON CONFLICT (vendor_id, name) DO NOTHING;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour calculer les statistiques de dépenses
CREATE OR REPLACE FUNCTION calculate_expense_stats(
    p_vendor_id UUID,
    p_start_date DATE DEFAULT NULL,
    p_end_date DATE DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    result JSONB;
    start_date DATE := COALESCE(p_start_date, CURRENT_DATE - INTERVAL '30 days');
    end_date DATE := COALESCE(p_end_date, CURRENT_DATE);
BEGIN
    SELECT jsonb_build_object(
        'total_expenses', COALESCE(SUM(amount), 0),
        'expense_count', COUNT(*),
        'average_expense', COALESCE(AVG(amount), 0),
        'categories', jsonb_agg(DISTINCT jsonb_build_object(
            'name', ec.name,
            'total', category_totals.total,
            'count', category_totals.count,
            'color', ec.color
        )),
        'payment_methods', jsonb_object_agg(
            payment_method, 
            payment_totals.total
        ),
        'monthly_trend', monthly_data.trend
    ) INTO result
    FROM vendor_expenses ve
    LEFT JOIN expense_categories ec ON ve.category_id = ec.id
    LEFT JOIN (
        SELECT category_id, SUM(amount) as total, COUNT(*) as count
        FROM vendor_expenses
        WHERE vendor_id = p_vendor_id 
        AND expense_date BETWEEN start_date AND end_date
        GROUP BY category_id
    ) category_totals ON ve.category_id = category_totals.category_id
    LEFT JOIN (
        SELECT payment_method, SUM(amount) as total
        FROM vendor_expenses
        WHERE vendor_id = p_vendor_id 
        AND expense_date BETWEEN start_date AND end_date
        GROUP BY payment_method
    ) payment_totals ON ve.payment_method = payment_totals.payment_method
    LEFT JOIN (
        SELECT jsonb_agg(jsonb_build_object(
            'month', TO_CHAR(expense_date, 'YYYY-MM'),
            'total', monthly_total
        ) ORDER BY expense_date) as trend
        FROM (
            SELECT DATE_TRUNC('month', expense_date) as expense_date, SUM(amount) as monthly_total
            FROM vendor_expenses
            WHERE vendor_id = p_vendor_id 
            AND expense_date BETWEEN start_date AND end_date
            GROUP BY DATE_TRUNC('month', expense_date)
        ) monthly_summary
    ) monthly_data ON true
    WHERE ve.vendor_id = p_vendor_id 
    AND ve.expense_date BETWEEN start_date AND end_date;
    
    RETURN COALESCE(result, '{}'::jsonb);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour détecter les anomalies de dépenses
CREATE OR REPLACE FUNCTION detect_expense_anomalies(p_vendor_id UUID)
RETURNS JSONB AS $$
DECLARE
    anomalies JSONB := '[]'::jsonb;
    avg_expense DECIMAL;
    std_dev DECIMAL;
    threshold DECIMAL;
BEGIN
    -- Calculer la moyenne et écart-type des dépenses des 90 derniers jours
    SELECT AVG(amount), STDDEV(amount) INTO avg_expense, std_dev
    FROM vendor_expenses
    WHERE vendor_id = p_vendor_id
    AND expense_date >= CURRENT_DATE - INTERVAL '90 days'
    AND status = 'approved';
    
    -- Seuil d'anomalie : moyenne + 2 * écart-type
    threshold := avg_expense + (2 * COALESCE(std_dev, 0));
    
    -- Détecter les dépenses anormalement élevées (derniers 7 jours)
    SELECT jsonb_agg(jsonb_build_object(
        'expense_id', id,
        'title', title,
        'amount', amount,
        'date', expense_date,
        'anomaly_type', 'high_amount',
        'severity', CASE 
            WHEN amount > threshold * 2 THEN 'critical'
            WHEN amount > threshold * 1.5 THEN 'high'
            ELSE 'medium'
        END,
        'description', 'Dépense anormalement élevée détectée'
    )) INTO anomalies
    FROM vendor_expenses
    WHERE vendor_id = p_vendor_id
    AND expense_date >= CURRENT_DATE - INTERVAL '7 days'
    AND amount > threshold
    AND status IN ('pending', 'approved');
    
    RETURN COALESCE(anomalies, '[]'::jsonb);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour mettre à jour les budgets automatiquement
CREATE OR REPLACE FUNCTION update_expense_budgets()
RETURNS TRIGGER AS $$
BEGIN
    -- Mettre à jour le montant dépensé pour la catégorie
    UPDATE expense_budgets
    SET spent_amount = (
        SELECT COALESCE(SUM(amount), 0)
        FROM vendor_expenses
        WHERE vendor_id = NEW.vendor_id
        AND category_id = NEW.category_id
        AND EXTRACT(YEAR FROM expense_date) = expense_budgets.year
        AND EXTRACT(MONTH FROM expense_date) = expense_budgets.month
        AND status = 'approved'
    ),
    updated_at = NOW()
    WHERE vendor_id = NEW.vendor_id
    AND category_id = NEW.category_id
    AND year = EXTRACT(YEAR FROM NEW.expense_date)
    AND month = EXTRACT(MONTH FROM NEW.expense_date);
    
    -- Créer une alerte si le budget est dépassé
    INSERT INTO expense_alerts (vendor_id, category_id, alert_type, title, message, severity)
    SELECT 
        eb.vendor_id,
        eb.category_id,
        'budget_exceeded',
        'Budget dépassé: ' || ec.name,
        'Le budget mensuel de ' || eb.planned_amount || ' XAF a été dépassé. Dépensé: ' || eb.spent_amount || ' XAF',
        'high'
    FROM expense_budgets eb
    JOIN expense_categories ec ON eb.category_id = ec.id
    WHERE eb.vendor_id = NEW.vendor_id
    AND eb.category_id = NEW.category_id
    AND eb.year = EXTRACT(YEAR FROM NEW.expense_date)
    AND eb.month = EXTRACT(MONTH FROM NEW.expense_date)
    AND eb.spent_amount > eb.planned_amount
    AND NOT EXISTS (
        SELECT 1 FROM expense_alerts ea
        WHERE ea.vendor_id = eb.vendor_id
        AND ea.category_id = eb.category_id
        AND ea.alert_type = 'budget_exceeded'
        AND DATE_TRUNC('month', ea.created_at) = DATE_TRUNC('month', NOW())
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ===================================================
-- TRIGGERS
-- ===================================================

-- Trigger pour mettre à jour les timestamps
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Appliquer le trigger aux tables principales
CREATE TRIGGER update_expense_categories_updated_at
    BEFORE UPDATE ON expense_categories
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_vendor_expenses_updated_at
    BEFORE UPDATE ON vendor_expenses
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_expense_budgets_updated_at
    BEFORE UPDATE ON expense_budgets
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Trigger pour mettre à jour les budgets automatiquement
CREATE TRIGGER update_budgets_on_expense_change
    AFTER INSERT OR UPDATE OF amount, status ON vendor_expenses
    FOR EACH ROW EXECUTE FUNCTION update_expense_budgets();

-- Trigger pour créer les catégories par défaut pour nouveaux vendeurs
CREATE OR REPLACE FUNCTION create_vendor_default_categories()
RETURNS TRIGGER AS $$
BEGIN
    -- Vérifier si c'est un vendeur
    IF NEW.role = 'vendeur' THEN
        PERFORM create_default_expense_categories(NEW.id);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER create_default_categories_for_new_vendor
    AFTER INSERT ON profiles
    FOR EACH ROW EXECUTE FUNCTION create_vendor_default_categories();

-- ===================================================
-- POLITIQUES DE SÉCURITÉ (RLS)
-- ===================================================

-- Activer RLS sur toutes les tables
ALTER TABLE expense_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_budgets ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_analytics ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_alerts ENABLE ROW LEVEL SECURITY;

-- Politiques pour expense_categories
CREATE POLICY "Vendors can manage their own categories" ON expense_categories
    FOR ALL USING (vendor_id = auth.uid());

-- Politiques pour vendor_expenses
CREATE POLICY "Vendors can manage their own expenses" ON vendor_expenses
    FOR ALL USING (vendor_id = auth.uid());

CREATE POLICY "PDG can view all expenses" ON vendor_expenses
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM profiles 
            WHERE id = auth.uid() 
            AND role IN ('admin', 'pdg')
        )
    );

-- Politiques pour expense_receipts
CREATE POLICY "Vendors can manage receipts for their expenses" ON expense_receipts
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM vendor_expenses 
            WHERE id = expense_receipts.expense_id 
            AND vendor_id = auth.uid()
        )
    );

-- Politiques pour expense_budgets
CREATE POLICY "Vendors can manage their own budgets" ON expense_budgets
    FOR ALL USING (vendor_id = auth.uid());

-- Politiques pour expense_analytics
CREATE POLICY "Vendors can view their own analytics" ON expense_analytics
    FOR SELECT USING (vendor_id = auth.uid());

CREATE POLICY "System can insert analytics" ON expense_analytics
    FOR INSERT WITH CHECK (true);

-- Politiques pour expense_alerts
CREATE POLICY "Vendors can manage their own alerts" ON expense_alerts
    FOR ALL USING (vendor_id = auth.uid());

-- ===================================================
-- DONNÉES DE TEST (OPTIONNEL)
-- ===================================================

-- Insérer quelques catégories de test pour le développement
-- (Sera remplacé par les catégories par défaut via trigger)

COMMENT ON TABLE expense_categories IS 'Catégories de dépenses personnalisables par vendeur';
COMMENT ON TABLE vendor_expenses IS 'Dépenses des vendeurs avec justificatifs et approbation';
COMMENT ON TABLE expense_receipts IS 'Justificatifs et reçus des dépenses avec OCR';
COMMENT ON TABLE expense_budgets IS 'Budgets mensuels par catégorie avec alertes';
COMMENT ON TABLE expense_analytics IS 'Analyses et insights IA sur les dépenses';
COMMENT ON TABLE expense_alerts IS 'Alertes et notifications liées aux dépenses';

-- ===================================================
-- FIN DE LA MIGRATION
-- ===================================================
