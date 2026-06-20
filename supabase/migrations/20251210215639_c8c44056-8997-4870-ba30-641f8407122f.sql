-- ===========================================
-- CERTIFICATIONS DE CONFORMITÉ ISO 27001 & PCI-DSS
-- ===========================================

-- Insérer les certifications ISO 27001 et PCI-DSS
INSERT INTO public.security_certifications (
  name, certification_type, status, progress, description, issuing_authority, valid_from, valid_until
) VALUES 
(
  'ISO 27001:2022',
  'iso27001',
  'in_progress',
  75,
  'Système de Management de la Sécurité de l''Information (SMSI). Norme internationale pour la gestion de la sécurité de l''information.',
  'ISO - Organisation Internationale de Normalisation',
  NULL,
  NULL
),
(
  'PCI-DSS v4.0',
  'pci_dss',
  'in_progress',
  68,
  'Payment Card Industry Data Security Standard. Conformité pour le traitement sécurisé des données de paiement.',
  'PCI Security Standards Council',
  NULL,
  NULL
),
(
  'SOC 2 Type II',
  'soc2',
  'planned',
  25,
  'Service Organization Control 2. Audit des contrôles de sécurité, disponibilité et confidentialité.',
  'AICPA',
  NULL,
  NULL
),
(
  'GDPR Compliance',
  'gdpr',
  'certified',
  100,
  'Règlement Général sur la Protection des Données. Conformité européenne pour la protection des données personnelles.',
  'Union Européenne',
  NOW() - INTERVAL '6 months',
  NOW() + INTERVAL '1 year'
)
ON CONFLICT DO NOTHING;

-- ===========================================
-- TABLE SOC ANALYSTS - Équipe de sécurité
-- ===========================================
CREATE TABLE IF NOT EXISTS public.soc_analysts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id),
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  analyst_role TEXT NOT NULL DEFAULT 'analyst',
  status TEXT NOT NULL DEFAULT 'available',
  specialization TEXT[],
  current_cases INT DEFAULT 0,
  max_cases INT DEFAULT 5,
  shift_start TIME,
  shift_end TIME,
  is_on_call BOOLEAN DEFAULT false,
  last_activity_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===========================================
-- TABLE SOC INVESTIGATIONS - Enquêtes approfondies
-- ===========================================
CREATE TABLE IF NOT EXISTS public.soc_investigations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id UUID REFERENCES public.security_incidents(id),
  alert_id UUID REFERENCES public.security_alerts(id),
  analyst_id UUID REFERENCES public.soc_analysts(id),
  title TEXT NOT NULL,
  description TEXT,
  priority TEXT NOT NULL DEFAULT 'medium',
  status TEXT NOT NULL DEFAULT 'open',
  investigation_type TEXT NOT NULL,
  findings TEXT,
  evidence JSONB DEFAULT '[]'::jsonb,
  timeline JSONB DEFAULT '[]'::jsonb,
  recommended_actions TEXT[],
  resolution_notes TEXT,
  escalated_to TEXT,
  time_spent_minutes INT DEFAULT 0,
  started_at TIMESTAMPTZ,
  closed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===========================================
-- TABLE ML FRAUD MODELS - Modèles ML pour fraude
-- ===========================================
CREATE TABLE IF NOT EXISTS public.ml_fraud_models (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  model_name TEXT NOT NULL,
  model_version TEXT NOT NULL,
  model_type TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  accuracy DECIMAL(5,2) DEFAULT 0,
  precision_score DECIMAL(5,2) DEFAULT 0,
  recall_score DECIMAL(5,2) DEFAULT 0,
  f1_score DECIMAL(5,2) DEFAULT 0,
  total_predictions BIGINT DEFAULT 0,
  true_positives BIGINT DEFAULT 0,
  false_positives BIGINT DEFAULT 0,
  features_used TEXT[],
  training_data_size BIGINT DEFAULT 0,
  last_trained_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===========================================
-- TABLE FRAUD PATTERNS - Patterns détectés par ML
-- ===========================================
CREATE TABLE IF NOT EXISTS public.ml_fraud_patterns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  model_id UUID REFERENCES public.ml_fraud_models(id),
  pattern_name TEXT NOT NULL,
  pattern_type TEXT NOT NULL,
  risk_score DECIMAL(5,2) NOT NULL DEFAULT 0,
  confidence DECIMAL(5,2) NOT NULL DEFAULT 0,
  occurrences INT DEFAULT 0,
  description TEXT,
  detection_rules JSONB DEFAULT '{}'::jsonb,
  is_active BOOLEAN DEFAULT true,
  last_detected_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===========================================
-- TABLE COMPLIANCE AUDITS - Audits de conformité
-- ===========================================
CREATE TABLE IF NOT EXISTS public.compliance_audits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  certification_id UUID REFERENCES public.security_certifications(id),
  audit_type TEXT NOT NULL,
  auditor_name TEXT,
  auditor_company TEXT,
  status TEXT NOT NULL DEFAULT 'scheduled',
  findings JSONB DEFAULT '[]'::jsonb,
  non_conformities INT DEFAULT 0,
  observations INT DEFAULT 0,
  recommendations TEXT[],
  overall_score DECIMAL(5,2),
  scheduled_date DATE,
  completed_date DATE,
  next_audit_date DATE,
  report_url TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===========================================
-- INSÉRER DONNÉES INITIALES
-- ===========================================

-- Modèles ML de fraude
INSERT INTO public.ml_fraud_models (model_name, model_version, model_type, status, accuracy, precision_score, recall_score, f1_score, features_used, total_predictions)
VALUES 
('FraudNet-Behavioral', 'v3.2.1', 'neural_network', 'active', 96.8, 94.5, 92.3, 93.4, 
 ARRAY['transaction_amount', 'velocity', 'device_fingerprint', 'geo_location', 'time_of_day', 'merchant_category', 'user_behavior_score'], 1500000),
('AnomalyDetector', 'v2.1.0', 'anomaly_detection', 'active', 94.2, 91.8, 95.1, 93.4,
 ARRAY['transaction_velocity', 'amount_deviation', 'geographic_anomaly', 'device_change', 'access_pattern'], 980000),
('VelocityGuard', 'v1.5.2', 'classification', 'active', 97.1, 96.2, 94.8, 95.5,
 ARRAY['transactions_per_hour', 'unique_recipients', 'average_amount', 'time_between_transactions'], 2100000)
ON CONFLICT DO NOTHING;

-- Patterns de fraude ML
INSERT INTO public.ml_fraud_patterns (pattern_name, pattern_type, risk_score, confidence, occurrences, description, detection_rules)
VALUES 
('Velocity Spike', 'velocity', 85, 94.5, 1247, 'Augmentation soudaine du nombre de transactions par heure', 
 '{"threshold": 10, "window_minutes": 60, "baseline_multiplier": 5}'::jsonb),
('Geographic Anomaly', 'geographic', 78, 89.2, 834, 'Transaction depuis une localisation inhabituelle', 
 '{"distance_km": 500, "time_window_hours": 2}'::jsonb),
('Amount Pattern Break', 'amount', 72, 91.3, 2156, 'Montant significativement différent du comportement habituel',
 '{"deviation_factor": 3, "min_transactions": 10}'::jsonb),
('Device Fingerprint Mismatch', 'behavior', 88, 96.1, 567, 'Appareil non reconnu avec tentative de transaction',
 '{"trust_score_threshold": 0.3}'::jsonb),
('Time Anomaly', 'temporal', 65, 87.4, 1893, 'Transaction à une heure inhabituelle pour cet utilisateur',
 '{"deviation_hours": 4, "confidence_threshold": 0.8}'::jsonb)
ON CONFLICT DO NOTHING;

-- SOC Analysts
INSERT INTO public.soc_analysts (name, email, analyst_role, status, specialization, current_cases, shift_start, shift_end, is_on_call)
VALUES 
('Mohamed Diallo', 'mohamed.diallo@224solution.net', 'senior_analyst', 'available', ARRAY['fraud', 'incident_response'], 2, '08:00', '17:00', false),
('Fatou Camara', 'fatou.camara@224solution.net', 'analyst', 'busy', ARRAY['network', 'malware'], 4, '08:00', '17:00', false),
('Ibrahima Bah', 'ibrahima.bah@224solution.net', 'team_lead', 'available', ARRAY['fraud', 'incident_response', 'compliance'], 1, '08:00', '17:00', true),
('Aissatou Sow', 'aissatou.sow@224solution.net', 'analyst', 'available', ARRAY['fraud', 'anomaly'], 3, '17:00', '01:00', false),
('Mamadou Barry', 'mamadou.barry@224solution.net', 'analyst', 'on_call', ARRAY['network', 'incident_response'], 0, '01:00', '08:00', true)
ON CONFLICT DO NOTHING;

-- Enable RLS
ALTER TABLE public.soc_analysts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.soc_investigations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ml_fraud_models ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ml_fraud_patterns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.compliance_audits ENABLE ROW LEVEL SECURITY;

-- RLS Policies pour admin/ceo (TEXT comparison instead of enum)
CREATE POLICY "Admins can manage SOC analysts" ON public.soc_analysts
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role::text IN ('admin', 'ceo'))
  );

CREATE POLICY "Admins can manage SOC investigations" ON public.soc_investigations
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role::text IN ('admin', 'ceo'))
  );

CREATE POLICY "Admins can view ML models" ON public.ml_fraud_models
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role::text IN ('admin', 'ceo'))
  );

CREATE POLICY "Admins can view ML patterns" ON public.ml_fraud_patterns
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role::text IN ('admin', 'ceo'))
  );

CREATE POLICY "Admins can manage compliance audits" ON public.compliance_audits
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role::text IN ('admin', 'ceo'))
  );

-- Indexes pour performance
CREATE INDEX IF NOT EXISTS idx_soc_analysts_status ON public.soc_analysts(status);
CREATE INDEX IF NOT EXISTS idx_soc_investigations_status ON public.soc_investigations(status);
CREATE INDEX IF NOT EXISTS idx_soc_investigations_analyst ON public.soc_investigations(analyst_id);
CREATE INDEX IF NOT EXISTS idx_ml_fraud_patterns_type ON public.ml_fraud_patterns(pattern_type);
CREATE INDEX IF NOT EXISTS idx_compliance_audits_cert ON public.compliance_audits(certification_id);