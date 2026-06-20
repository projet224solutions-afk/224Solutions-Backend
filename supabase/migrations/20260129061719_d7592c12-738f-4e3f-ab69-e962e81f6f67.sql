-- =====================================================
-- SYSTÈME D'AFFILIATION AGENT - TABLES PRINCIPALES
-- =====================================================

-- 1. Table des liens d'affiliation générés par les agents
CREATE TABLE IF NOT EXISTS public.agent_affiliate_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id UUID NOT NULL REFERENCES public.agents_management(id) ON DELETE CASCADE,
  token VARCHAR(64) UNIQUE NOT NULL,
  name VARCHAR(255), -- Nom de la campagne (optionnel)
  target_role VARCHAR(50) DEFAULT 'all', -- 'client', 'vendeur', 'service', 'all'
  commission_override NUMERIC(5,2), -- Commission spécifique pour ce lien (optionnel)
  clicks_count INTEGER DEFAULT 0,
  registrations_count INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  expires_at TIMESTAMP WITH TIME ZONE,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 2. Table de tracking des clics sur les liens
CREATE TABLE IF NOT EXISTS public.affiliate_link_clicks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  link_id UUID NOT NULL REFERENCES public.agent_affiliate_links(id) ON DELETE CASCADE,
  ip_address INET,
  user_agent TEXT,
  referrer TEXT,
  device_type VARCHAR(50),
  country VARCHAR(100),
  city VARCHAR(100),
  fingerprint VARCHAR(255), -- Device fingerprint pour anti-fraude
  clicked_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 3. Table de rattachement utilisateur -> agent (affiliation)
CREATE TABLE IF NOT EXISTS public.user_agent_affiliations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE, -- Un utilisateur = un seul agent
  agent_id UUID NOT NULL REFERENCES public.agents_management(id) ON DELETE SET NULL,
  affiliate_link_id UUID REFERENCES public.agent_affiliate_links(id) ON DELETE SET NULL,
  affiliate_token VARCHAR(64),
  registration_ip INET,
  device_fingerprint VARCHAR(255),
  is_verified BOOLEAN DEFAULT false, -- Vérifié après période probatoire
  verified_at TIMESTAMP WITH TIME ZONE,
  fraud_score INTEGER DEFAULT 0, -- Score de fraude (0-100)
  fraud_flags JSONB DEFAULT '[]',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 4. Table des commissions agents (enrichie)
CREATE TABLE IF NOT EXISTS public.agent_affiliate_commissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id UUID NOT NULL REFERENCES public.agents_management(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  affiliation_id UUID REFERENCES public.user_agent_affiliations(id),
  transaction_id UUID,
  transaction_type VARCHAR(100) NOT NULL, -- 'subscription', 'sale', 'service_payment', 'registration_bonus'
  transaction_amount NUMERIC(15,2) NOT NULL,
  commission_rate NUMERIC(5,2) NOT NULL,
  commission_amount NUMERIC(15,2) NOT NULL,
  currency VARCHAR(10) DEFAULT 'GNF',
  status VARCHAR(50) DEFAULT 'pending', -- 'pending', 'validated', 'paid', 'cancelled', 'disputed'
  validation_date TIMESTAMP WITH TIME ZONE, -- Date de validation après délai sécurité
  paid_at TIMESTAMP WITH TIME ZONE,
  paid_by UUID,
  notes TEXT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 5. Table de configuration des règles de commission par type
CREATE TABLE IF NOT EXISTS public.agent_commission_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pdg_id UUID NOT NULL REFERENCES public.pdg_management(id) ON DELETE CASCADE,
  transaction_type VARCHAR(100) NOT NULL,
  default_rate NUMERIC(5,2) NOT NULL,
  min_rate NUMERIC(5,2) DEFAULT 0,
  max_rate NUMERIC(5,2) DEFAULT 50,
  validation_delay_hours INTEGER DEFAULT 72, -- Délai avant validation
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(pdg_id, transaction_type)
);

-- 6. Table de logs anti-fraude
CREATE TABLE IF NOT EXISTS public.affiliate_fraud_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id UUID REFERENCES public.agents_management(id),
  user_id UUID,
  link_id UUID REFERENCES public.agent_affiliate_links(id),
  fraud_type VARCHAR(100) NOT NULL, -- 'multi_account', 'self_referral', 'ip_abuse', 'device_abuse', 'velocity'
  severity VARCHAR(20) DEFAULT 'low', -- 'low', 'medium', 'high', 'critical'
  details JSONB NOT NULL,
  ip_address INET,
  device_fingerprint VARCHAR(255),
  action_taken VARCHAR(100), -- 'flagged', 'blocked', 'commission_cancelled', 'agent_suspended'
  resolved BOOLEAN DEFAULT false,
  resolved_by UUID,
  resolved_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- =====================================================
-- INDEX POUR PERFORMANCE
-- =====================================================

CREATE INDEX IF NOT EXISTS idx_affiliate_links_agent ON public.agent_affiliate_links(agent_id);
CREATE INDEX IF NOT EXISTS idx_affiliate_links_token ON public.agent_affiliate_links(token);
CREATE INDEX IF NOT EXISTS idx_affiliate_links_active ON public.agent_affiliate_links(is_active) WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_link_clicks_link ON public.affiliate_link_clicks(link_id);
CREATE INDEX IF NOT EXISTS idx_link_clicks_ip ON public.affiliate_link_clicks(ip_address);
CREATE INDEX IF NOT EXISTS idx_link_clicks_fingerprint ON public.affiliate_link_clicks(fingerprint);

CREATE INDEX IF NOT EXISTS idx_user_affiliations_user ON public.user_agent_affiliations(user_id);
CREATE INDEX IF NOT EXISTS idx_user_affiliations_agent ON public.user_agent_affiliations(agent_id);
CREATE INDEX IF NOT EXISTS idx_user_affiliations_token ON public.user_agent_affiliations(affiliate_token);

CREATE INDEX IF NOT EXISTS idx_affiliate_commissions_agent ON public.agent_affiliate_commissions(agent_id);
CREATE INDEX IF NOT EXISTS idx_affiliate_commissions_status ON public.agent_affiliate_commissions(status);
CREATE INDEX IF NOT EXISTS idx_affiliate_commissions_user ON public.agent_affiliate_commissions(user_id);

CREATE INDEX IF NOT EXISTS idx_fraud_logs_agent ON public.affiliate_fraud_logs(agent_id);
CREATE INDEX IF NOT EXISTS idx_fraud_logs_type ON public.affiliate_fraud_logs(fraud_type);

-- =====================================================
-- RLS POLICIES
-- =====================================================

ALTER TABLE public.agent_affiliate_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_link_clicks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_agent_affiliations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_affiliate_commissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_commission_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.affiliate_fraud_logs ENABLE ROW LEVEL SECURITY;

-- Policies pour agent_affiliate_links
CREATE POLICY "Agents can view their own links"
  ON public.agent_affiliate_links FOR SELECT
  USING (
    agent_id IN (SELECT id FROM public.agents_management WHERE user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.pdg_management WHERE user_id = auth.uid())
  );

CREATE POLICY "Agents can create their own links"
  ON public.agent_affiliate_links FOR INSERT
  WITH CHECK (
    agent_id IN (SELECT id FROM public.agents_management WHERE user_id = auth.uid())
  );

CREATE POLICY "Agents can update their own links"
  ON public.agent_affiliate_links FOR UPDATE
  USING (
    agent_id IN (SELECT id FROM public.agents_management WHERE user_id = auth.uid())
  );

-- Policies pour affiliate_link_clicks (lecture seule pour agents)
CREATE POLICY "Agents can view clicks on their links"
  ON public.affiliate_link_clicks FOR SELECT
  USING (
    link_id IN (
      SELECT id FROM public.agent_affiliate_links 
      WHERE agent_id IN (SELECT id FROM public.agents_management WHERE user_id = auth.uid())
    )
    OR EXISTS (SELECT 1 FROM public.pdg_management WHERE user_id = auth.uid())
  );

-- Policies pour user_agent_affiliations
CREATE POLICY "Agents can view their affiliations"
  ON public.user_agent_affiliations FOR SELECT
  USING (
    agent_id IN (SELECT id FROM public.agents_management WHERE user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.pdg_management WHERE user_id = auth.uid())
  );

-- Policies pour agent_affiliate_commissions
CREATE POLICY "Agents can view their commissions"
  ON public.agent_affiliate_commissions FOR SELECT
  USING (
    agent_id IN (SELECT id FROM public.agents_management WHERE user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.pdg_management WHERE user_id = auth.uid())
  );

-- Policies pour agent_commission_rules (lecture pour tous, écriture PDG)
CREATE POLICY "Anyone can view commission rules"
  ON public.agent_commission_rules FOR SELECT
  USING (true);

CREATE POLICY "PDG can manage commission rules"
  ON public.agent_commission_rules FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.pdg_management WHERE user_id = auth.uid())
  );

-- Policies pour affiliate_fraud_logs (PDG uniquement)
CREATE POLICY "PDG can view fraud logs"
  ON public.affiliate_fraud_logs FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM public.pdg_management WHERE user_id = auth.uid())
  );

-- =====================================================
-- TRIGGERS
-- =====================================================

-- Trigger pour updated_at
CREATE OR REPLACE FUNCTION public.update_affiliate_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_affiliate_links_updated
  BEFORE UPDATE ON public.agent_affiliate_links
  FOR EACH ROW EXECUTE FUNCTION public.update_affiliate_updated_at();

CREATE TRIGGER trigger_affiliate_commissions_updated
  BEFORE UPDATE ON public.agent_affiliate_commissions
  FOR EACH ROW EXECUTE FUNCTION public.update_affiliate_updated_at();

CREATE TRIGGER trigger_commission_rules_updated
  BEFORE UPDATE ON public.agent_commission_rules
  FOR EACH ROW EXECUTE FUNCTION public.update_affiliate_updated_at();

-- =====================================================
-- FONCTION POUR CALCUL AUTOMATIQUE DES COMMISSIONS
-- =====================================================

CREATE OR REPLACE FUNCTION public.calculate_agent_commission(
  p_user_id UUID,
  p_transaction_type VARCHAR,
  p_amount NUMERIC,
  p_transaction_id UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
  v_affiliation RECORD;
  v_agent RECORD;
  v_rule RECORD;
  v_commission_rate NUMERIC;
  v_commission_amount NUMERIC;
  v_commission_id UUID;
BEGIN
  -- Trouver l'affiliation de l'utilisateur
  SELECT * INTO v_affiliation 
  FROM public.user_agent_affiliations 
  WHERE user_id = p_user_id 
  AND is_verified = true
  LIMIT 1;

  IF v_affiliation IS NULL THEN
    RETURN NULL;
  END IF;

  -- Récupérer l'agent
  SELECT * INTO v_agent 
  FROM public.agents_management 
  WHERE id = v_affiliation.agent_id 
  AND is_active = true;

  IF v_agent IS NULL THEN
    RETURN NULL;
  END IF;

  -- Récupérer la règle de commission
  SELECT * INTO v_rule 
  FROM public.agent_commission_rules 
  WHERE pdg_id = v_agent.pdg_id 
  AND transaction_type = p_transaction_type 
  AND is_active = true;

  -- Utiliser le taux de l'agent ou le taux par défaut
  v_commission_rate := COALESCE(v_agent.commission_rate, COALESCE(v_rule.default_rate, 5));
  v_commission_amount := p_amount * v_commission_rate / 100;

  -- Créer l'entrée de commission
  INSERT INTO public.agent_affiliate_commissions (
    agent_id,
    user_id,
    affiliation_id,
    transaction_id,
    transaction_type,
    transaction_amount,
    commission_rate,
    commission_amount,
    status,
    validation_date
  ) VALUES (
    v_affiliation.agent_id,
    p_user_id,
    v_affiliation.id,
    p_transaction_id,
    p_transaction_type,
    p_amount,
    v_commission_rate,
    v_commission_amount,
    'pending',
    NOW() + INTERVAL '72 hours' -- Délai de validation par défaut
  ) RETURNING id INTO v_commission_id;

  RETURN v_commission_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;