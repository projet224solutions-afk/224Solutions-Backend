-- =====================================================
-- VENDOR AI ENTERPRISE - Tables de Gouvernance et Audit
-- =====================================================

-- Table pour les décisions et recommandations IA
CREATE TABLE IF NOT EXISTS public.vendor_ai_decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  decision_type TEXT NOT NULL, -- 'review_response', 'order_action', 'stock_alert', 'marketing_campaign', 'document_generation'
  ai_recommendation TEXT NOT NULL,
  ai_confidence DECIMAL(3,2) DEFAULT 0.00, -- 0.00 à 1.00
  context_data JSONB DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'pending', -- 'pending', 'approved', 'rejected', 'executed', 'expired'
  approved_by UUID REFERENCES auth.users(id),
  approved_at TIMESTAMPTZ,
  executed_at TIMESTAMPTZ,
  rejection_reason TEXT,
  priority TEXT DEFAULT 'normal', -- 'low', 'normal', 'high', 'critical'
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table pour l'historique des prompts IA (versionnage)
CREATE TABLE IF NOT EXISTS public.vendor_ai_prompt_versions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  prompt_name TEXT NOT NULL,
  prompt_type TEXT NOT NULL, -- 'sentiment', 'order', 'stock', 'marketing', 'document'
  prompt_content TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  is_active BOOLEAN DEFAULT true,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(prompt_name, version)
);

-- Table pour les logs d'exécution IA
CREATE TABLE IF NOT EXISTS public.vendor_ai_execution_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  decision_id UUID REFERENCES public.vendor_ai_decisions(id),
  action_type TEXT NOT NULL,
  input_data JSONB DEFAULT '{}',
  output_data JSONB DEFAULT '{}',
  execution_time_ms INTEGER,
  tokens_used INTEGER,
  model_used TEXT,
  success BOOLEAN DEFAULT true,
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table pour l'analyse des sentiments des avis
CREATE TABLE IF NOT EXISTS public.vendor_review_sentiment_analysis (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  review_id UUID, -- peut être vendor_ratings.id ou product_reviews.id
  review_type TEXT NOT NULL, -- 'vendor_rating', 'product_review'
  original_text TEXT NOT NULL,
  sentiment TEXT NOT NULL, -- 'positive', 'neutral', 'negative', 'critical'
  sentiment_score DECIMAL(3,2), -- -1.00 à 1.00
  urgency_level TEXT DEFAULT 'normal', -- 'low', 'normal', 'high', 'urgent'
  key_topics TEXT[], -- ['livraison', 'qualité', 'prix', 'service']
  ai_suggested_response TEXT,
  response_approved BOOLEAN DEFAULT false,
  response_approved_by UUID REFERENCES auth.users(id),
  final_response TEXT,
  responded_at TIMESTAMPTZ,
  analyzed_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table pour les alertes de stock intelligentes
CREATE TABLE IF NOT EXISTS public.vendor_stock_ai_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  alert_type TEXT NOT NULL, -- 'low_stock', 'overstock', 'stockout_risk', 'optimal_reorder'
  current_stock INTEGER,
  predicted_stockout_date DATE,
  recommended_quantity INTEGER,
  recommendation_basis TEXT, -- Explication de la recommandation
  confidence DECIMAL(3,2),
  status TEXT DEFAULT 'active', -- 'active', 'acknowledged', 'resolved', 'ignored'
  acknowledged_by UUID REFERENCES auth.users(id),
  acknowledged_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table pour les campagnes marketing proposées par l'IA
CREATE TABLE IF NOT EXISTS public.vendor_ai_marketing_campaigns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  campaign_name TEXT NOT NULL,
  campaign_type TEXT NOT NULL, -- 'sms', 'push', 'email', 'in_app'
  target_segment TEXT, -- 'all', 'inactive', 'loyal', 'new', 'high_value'
  target_customer_count INTEGER,
  message_content TEXT NOT NULL,
  ai_reasoning TEXT, -- Pourquoi cette campagne est recommandée
  predicted_conversion_rate DECIMAL(5,2),
  status TEXT DEFAULT 'proposed', -- 'proposed', 'approved', 'scheduled', 'sent', 'cancelled'
  approved_by UUID REFERENCES auth.users(id),
  approved_at TIMESTAMPTZ,
  scheduled_at TIMESTAMPTZ,
  sent_at TIMESTAMPTZ,
  results JSONB DEFAULT '{}', -- Résultats de la campagne
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table pour les documents générés par l'IA
CREATE TABLE IF NOT EXISTS public.vendor_ai_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  document_type TEXT NOT NULL, -- 'user_guide', 'manual', 'report', 'invoice', 'custom'
  document_title TEXT NOT NULL,
  document_content JSONB NOT NULL, -- Structure du document
  pdf_url TEXT,
  language TEXT DEFAULT 'fr',
  generated_by TEXT DEFAULT 'ai', -- 'ai', 'manual'
  status TEXT DEFAULT 'draft', -- 'draft', 'generated', 'downloaded'
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table pour le kill-switch et contrôle IA
CREATE TABLE IF NOT EXISTS public.vendor_ai_control (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  ai_enabled BOOLEAN DEFAULT true,
  disabled_by UUID REFERENCES auth.users(id),
  disabled_at TIMESTAMPTZ,
  disable_reason TEXT,
  auto_approve_reviews BOOLEAN DEFAULT false,
  auto_approve_stock_alerts BOOLEAN DEFAULT false,
  auto_approve_marketing BOOLEAN DEFAULT false,
  max_daily_executions INTEGER DEFAULT 100,
  executions_today INTEGER DEFAULT 0,
  last_reset_date DATE DEFAULT CURRENT_DATE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(vendor_id)
);

-- Enable RLS
ALTER TABLE public.vendor_ai_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_ai_prompt_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_ai_execution_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_review_sentiment_analysis ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_stock_ai_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_ai_marketing_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_ai_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_ai_control ENABLE ROW LEVEL SECURITY;

-- RLS Policies - Vendors can only see their own data
CREATE POLICY "Vendors can view own AI decisions" ON public.vendor_ai_decisions
  FOR SELECT USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Vendors can update own AI decisions" ON public.vendor_ai_decisions
  FOR UPDATE USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Service role can manage AI decisions" ON public.vendor_ai_decisions
  FOR ALL USING (true);

CREATE POLICY "Vendors can view own AI logs" ON public.vendor_ai_execution_logs
  FOR SELECT USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Service role can manage AI logs" ON public.vendor_ai_execution_logs
  FOR ALL USING (true);

CREATE POLICY "Vendors can view own sentiment analysis" ON public.vendor_review_sentiment_analysis
  FOR SELECT USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Vendors can update own sentiment analysis" ON public.vendor_review_sentiment_analysis
  FOR UPDATE USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Service role can manage sentiment analysis" ON public.vendor_review_sentiment_analysis
  FOR ALL USING (true);

CREATE POLICY "Vendors can view own stock alerts" ON public.vendor_stock_ai_alerts
  FOR SELECT USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Vendors can update own stock alerts" ON public.vendor_stock_ai_alerts
  FOR UPDATE USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Service role can manage stock alerts" ON public.vendor_stock_ai_alerts
  FOR ALL USING (true);

CREATE POLICY "Vendors can view own marketing campaigns" ON public.vendor_ai_marketing_campaigns
  FOR SELECT USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Vendors can update own marketing campaigns" ON public.vendor_ai_marketing_campaigns
  FOR UPDATE USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Service role can manage marketing campaigns" ON public.vendor_ai_marketing_campaigns
  FOR ALL USING (true);

CREATE POLICY "Vendors can view own documents" ON public.vendor_ai_documents
  FOR SELECT USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Service role can manage documents" ON public.vendor_ai_documents
  FOR ALL USING (true);

CREATE POLICY "Vendors can view own AI control" ON public.vendor_ai_control
  FOR SELECT USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Vendors can update own AI control" ON public.vendor_ai_control
  FOR UPDATE USING (
    vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
  );

CREATE POLICY "Service role can manage AI control" ON public.vendor_ai_control
  FOR ALL USING (true);

CREATE POLICY "Anyone can view prompt versions" ON public.vendor_ai_prompt_versions
  FOR SELECT USING (true);

CREATE POLICY "Service role can manage prompt versions" ON public.vendor_ai_prompt_versions
  FOR ALL USING (true);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_vendor_ai_decisions_vendor ON public.vendor_ai_decisions(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_ai_decisions_status ON public.vendor_ai_decisions(status);
CREATE INDEX IF NOT EXISTS idx_vendor_ai_decisions_type ON public.vendor_ai_decisions(decision_type);
CREATE INDEX IF NOT EXISTS idx_vendor_ai_logs_vendor ON public.vendor_ai_execution_logs(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_sentiment_vendor ON public.vendor_review_sentiment_analysis(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_stock_alerts_vendor ON public.vendor_stock_ai_alerts(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_stock_alerts_product ON public.vendor_stock_ai_alerts(product_id);
CREATE INDEX IF NOT EXISTS idx_vendor_marketing_vendor ON public.vendor_ai_marketing_campaigns(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_documents_vendor ON public.vendor_ai_documents(vendor_id);

-- Insert default AI prompts
INSERT INTO public.vendor_ai_prompt_versions (prompt_name, prompt_type, prompt_content, version, is_active) VALUES
('sentiment_analysis_v1', 'sentiment', 'Analyse le sentiment de cet avis client. Détermine: 1) Le sentiment (positif/neutre/négatif/critique) 2) Le score de -1 à 1 3) Les thèmes principaux (livraison, qualité, prix, service) 4) Le niveau d''urgence 5) Une réponse professionnelle suggérée.', 1, true),
('stock_prediction_v1', 'stock', 'Analyse les données de vente et de stock pour ce produit. Prédit: 1) Risque de rupture 2) Date estimée de rupture 3) Quantité optimale à commander 4) Justification de la recommandation.', 1, true),
('marketing_campaign_v1', 'marketing', 'Analyse les performances du vendeur et propose une campagne marketing ciblée. Inclure: 1) Segment cible 2) Type de campagne 3) Message personnalisé 4) Taux de conversion prédit 5) Justification.', 1, true),
('order_analysis_v1', 'order', 'Analyse cette commande pour détecter: 1) Risques potentiels (retard, fraude, litige) 2) Priorité de traitement 3) Actions recommandées 4) Notes pour le vendeur.', 1, true),
('document_generation_v1', 'document', 'Génère un document professionnel avec: 1) Page de couverture 2) Sommaire structuré 3) Contenu hiérarchisé 4) Style entreprise 5) Personnalisation boutique.', 1, true)
ON CONFLICT (prompt_name, version) DO NOTHING;