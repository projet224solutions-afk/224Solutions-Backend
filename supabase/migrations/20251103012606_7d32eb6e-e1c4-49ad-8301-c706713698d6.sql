-- Phase 1: Analytics & Security Tables

-- Table pour les statistiques vendeur (analytics)
CREATE TABLE IF NOT EXISTS vendor_analytics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  date DATE NOT NULL DEFAULT CURRENT_DATE,
  total_sales DECIMAL(10,2) DEFAULT 0,
  total_orders INTEGER DEFAULT 0,
  conversion_rate DECIMAL(5,2) DEFAULT 0,
  top_product_id UUID,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(vendor_id, date)
);

-- Table pour les notifications en temps réel
CREATE TABLE IF NOT EXISTS vendor_notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('order', 'payment', 'message', 'security', 'stock')),
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  data JSONB,
  read BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table pour la vérification d'identité (KYC)
CREATE TABLE IF NOT EXISTS vendor_kyc (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL UNIQUE REFERENCES profiles(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'verified', 'rejected', 'under_review')),
  phone_verified BOOLEAN DEFAULT FALSE,
  phone_number TEXT,
  id_document_url TEXT,
  id_document_type TEXT,
  verified_at TIMESTAMPTZ,
  rejection_reason TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table pour le score de confiance vendeur
CREATE TABLE IF NOT EXISTS vendor_trust_score (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL UNIQUE REFERENCES profiles(id) ON DELETE CASCADE,
  score INTEGER DEFAULT 50 CHECK (score >= 0 AND score <= 100),
  total_sales INTEGER DEFAULT 0,
  successful_orders INTEGER DEFAULT 0,
  cancelled_orders INTEGER DEFAULT 0,
  disputes INTEGER DEFAULT 0,
  response_time_avg INTEGER DEFAULT 0, -- en minutes
  account_age_days INTEGER DEFAULT 0,
  last_calculated_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table pour les activités suspectes (anti-fraude)
CREATE TABLE IF NOT EXISTS suspicious_activities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  activity_type TEXT NOT NULL CHECK (activity_type IN ('unusual_login', 'high_volume_orders', 'suspicious_transaction', 'multiple_failed_payments', 'unusual_location')),
  severity TEXT NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  description TEXT NOT NULL,
  metadata JSONB,
  ip_address TEXT,
  resolved BOOLEAN DEFAULT FALSE,
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes pour performance
CREATE INDEX idx_vendor_analytics_vendor_date ON vendor_analytics(vendor_id, date DESC);
CREATE INDEX idx_vendor_notifications_vendor_read ON vendor_notifications(vendor_id, read, created_at DESC);
CREATE INDEX idx_vendor_kyc_status ON vendor_kyc(vendor_id, status);
CREATE INDEX idx_vendor_trust_score_vendor ON vendor_trust_score(vendor_id);
CREATE INDEX idx_suspicious_activities_vendor ON suspicious_activities(vendor_id, resolved, created_at DESC);

-- Enable RLS
ALTER TABLE vendor_analytics ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_kyc ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_trust_score ENABLE ROW LEVEL SECURITY;
ALTER TABLE suspicious_activities ENABLE ROW LEVEL SECURITY;

-- RLS Policies pour vendor_analytics
CREATE POLICY "Vendors can view their own analytics"
  ON vendor_analytics FOR SELECT
  USING (auth.uid() = vendor_id);

-- RLS Policies pour vendor_notifications
CREATE POLICY "Vendors can view their own notifications"
  ON vendor_notifications FOR SELECT
  USING (auth.uid() = vendor_id);

CREATE POLICY "Vendors can update their own notifications"
  ON vendor_notifications FOR UPDATE
  USING (auth.uid() = vendor_id);

-- RLS Policies pour vendor_kyc
CREATE POLICY "Vendors can view their own KYC"
  ON vendor_kyc FOR SELECT
  USING (auth.uid() = vendor_id);

CREATE POLICY "Vendors can update their own KYC"
  ON vendor_kyc FOR UPDATE
  USING (auth.uid() = vendor_id);

CREATE POLICY "Vendors can insert their own KYC"
  ON vendor_kyc FOR INSERT
  WITH CHECK (auth.uid() = vendor_id);

-- RLS Policies pour vendor_trust_score
CREATE POLICY "Vendors can view their own trust score"
  ON vendor_trust_score FOR SELECT
  USING (auth.uid() = vendor_id);

-- RLS Policies pour suspicious_activities (admins only pour INSERT)
CREATE POLICY "Vendors can view their own suspicious activities"
  ON suspicious_activities FOR SELECT
  USING (auth.uid() = vendor_id);

-- Fonction pour calculer le score de confiance
CREATE OR REPLACE FUNCTION calculate_vendor_trust_score(p_vendor_id UUID)
RETURNS INTEGER AS $$
DECLARE
  v_score INTEGER := 50;
  v_total_sales INTEGER;
  v_successful_orders INTEGER;
  v_cancelled_orders INTEGER;
  v_disputes INTEGER;
  v_account_age_days INTEGER;
BEGIN
  SELECT 
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0)
  INTO v_total_sales, v_successful_orders, v_cancelled_orders
  FROM payment_links
  WHERE vendor_id = p_vendor_id;
  
  SELECT EXTRACT(DAY FROM NOW() - created_at)::INTEGER
  INTO v_account_age_days
  FROM profiles
  WHERE id = p_vendor_id;
  
  -- Calcul du score (algorithme simple)
  v_score := 50; -- Base
  
  -- Bonus pour commandes réussies
  v_score := v_score + LEAST(v_successful_orders * 2, 30);
  
  -- Malus pour annulations
  v_score := v_score - (v_cancelled_orders * 5);
  
  -- Bonus pour ancienneté
  v_score := v_score + LEAST(v_account_age_days / 10, 10);
  
  -- Garder le score entre 0 et 100
  v_score := GREATEST(0, LEAST(100, v_score));
  
  -- Mettre à jour la table
  INSERT INTO vendor_trust_score (vendor_id, score, total_sales, successful_orders, cancelled_orders, account_age_days)
  VALUES (p_vendor_id, v_score, v_total_sales, v_successful_orders, v_cancelled_orders, v_account_age_days)
  ON CONFLICT (vendor_id) 
  DO UPDATE SET 
    score = v_score,
    total_sales = v_total_sales,
    successful_orders = v_successful_orders,
    cancelled_orders = v_cancelled_orders,
    account_age_days = v_account_age_days,
    last_calculated_at = NOW();
  
  RETURN v_score;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour créer une notification
CREATE OR REPLACE FUNCTION create_vendor_notification(
  p_vendor_id UUID,
  p_type TEXT,
  p_title TEXT,
  p_message TEXT,
  p_data JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
  v_notification_id UUID;
BEGIN
  INSERT INTO vendor_notifications (vendor_id, type, title, message, data)
  VALUES (p_vendor_id, p_type, p_title, p_message, p_data)
  RETURNING id INTO v_notification_id;
  
  RETURN v_notification_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Enable realtime for notifications
ALTER TABLE vendor_notifications REPLICA IDENTITY FULL;