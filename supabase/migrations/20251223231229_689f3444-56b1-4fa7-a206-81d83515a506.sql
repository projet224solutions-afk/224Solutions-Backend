-- =============================================
-- SYSTÈME D'ABONNEMENT POUR SERVICES PROFESSIONNELS
-- =============================================

-- Plans spécifiques pour les services professionnels
CREATE TABLE public.service_plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_type_id UUID REFERENCES public.service_types(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  display_name TEXT NOT NULL,
  description TEXT,
  monthly_price_gnf INTEGER NOT NULL DEFAULT 0,
  yearly_price_gnf INTEGER DEFAULT 0,
  yearly_discount_percentage DECIMAL(5,2) DEFAULT 10,
  features JSONB DEFAULT '[]'::jsonb,
  max_bookings_per_month INTEGER,
  max_products INTEGER,
  max_staff INTEGER,
  priority_listing BOOLEAN DEFAULT false,
  analytics_access BOOLEAN DEFAULT false,
  sms_notifications BOOLEAN DEFAULT false,
  email_notifications BOOLEAN DEFAULT true,
  custom_branding BOOLEAN DEFAULT false,
  api_access BOOLEAN DEFAULT false,
  display_order INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Abonnements des services professionnels
CREATE TABLE public.service_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  plan_id UUID NOT NULL REFERENCES public.service_plans(id),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'expired', 'cancelled', 'past_due', 'trialing')),
  billing_cycle TEXT NOT NULL DEFAULT 'monthly' CHECK (billing_cycle IN ('monthly', 'yearly', 'lifetime', 'custom')),
  price_paid_gnf INTEGER NOT NULL DEFAULT 0,
  payment_method TEXT DEFAULT 'wallet',
  payment_transaction_id TEXT,
  started_at TIMESTAMPTZ DEFAULT now(),
  current_period_start TIMESTAMPTZ DEFAULT now(),
  current_period_end TIMESTAMPTZ NOT NULL,
  auto_renew BOOLEAN DEFAULT true,
  cancelled_at TIMESTAMPTZ,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Historique des prix des plans de services
CREATE TABLE public.service_plan_price_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id UUID NOT NULL REFERENCES public.service_plans(id) ON DELETE CASCADE,
  old_price INTEGER NOT NULL,
  new_price INTEGER NOT NULL,
  changed_by UUID,
  reason TEXT,
  changed_at TIMESTAMPTZ DEFAULT now()
);

-- Transactions de paiement des abonnements de services
CREATE TABLE public.service_subscription_payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_id UUID NOT NULL REFERENCES public.service_subscriptions(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  amount_gnf INTEGER NOT NULL,
  payment_method TEXT NOT NULL,
  transaction_reference TEXT,
  status TEXT DEFAULT 'completed' CHECK (status IN ('pending', 'completed', 'failed', 'refunded')),
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Index pour performances
CREATE INDEX idx_service_plans_service_type ON public.service_plans(service_type_id);
CREATE INDEX idx_service_plans_active ON public.service_plans(is_active);
CREATE INDEX idx_service_subscriptions_user ON public.service_subscriptions(user_id);
CREATE INDEX idx_service_subscriptions_service ON public.service_subscriptions(professional_service_id);
CREATE INDEX idx_service_subscriptions_status ON public.service_subscriptions(status);
CREATE INDEX idx_service_subscriptions_end_date ON public.service_subscriptions(current_period_end);
CREATE INDEX idx_service_subscription_payments_sub ON public.service_subscription_payments(subscription_id);

-- RLS
ALTER TABLE public.service_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_plan_price_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_subscription_payments ENABLE ROW LEVEL SECURITY;

-- Policies pour service_plans (lecture publique)
CREATE POLICY "Service plans are viewable by everyone" 
ON public.service_plans FOR SELECT USING (true);

CREATE POLICY "Only admins can modify service plans" 
ON public.service_plans FOR ALL USING (
  EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('ceo', 'admin'))
);

-- Policies pour service_subscriptions
CREATE POLICY "Users can view their own service subscriptions" 
ON public.service_subscriptions FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Admins can view all service subscriptions" 
ON public.service_subscriptions FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('ceo', 'admin'))
);

CREATE POLICY "Users can insert their own service subscriptions" 
ON public.service_subscriptions FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Admins can manage all service subscriptions" 
ON public.service_subscriptions FOR ALL USING (
  EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('ceo', 'admin'))
);

-- Policies pour historique prix
CREATE POLICY "Admins can view price history" 
ON public.service_plan_price_history FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('ceo', 'admin'))
);

CREATE POLICY "Admins can manage price history" 
ON public.service_plan_price_history FOR ALL USING (
  EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('ceo', 'admin'))
);

-- Policies pour paiements
CREATE POLICY "Users can view their own payments" 
ON public.service_subscription_payments FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own payments" 
ON public.service_subscription_payments FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Admins can view all payments" 
ON public.service_subscription_payments FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('ceo', 'admin'))
);

-- =============================================
-- INSERTION DES PLANS PAR DÉFAUT
-- =============================================

-- Plan Gratuit (pour tous les types de services)
INSERT INTO public.service_plans (name, display_name, description, monthly_price_gnf, features, max_bookings_per_month, max_products, max_staff, display_order)
VALUES 
('free', 'Gratuit', 'Plan de base pour démarrer', 0, 
 '["Profil public", "Réservations basiques", "Dashboard simple", "Notifications email"]'::jsonb,
 10, 5, 1, 0);

-- Plan Basic
INSERT INTO public.service_plans (name, display_name, description, monthly_price_gnf, yearly_price_gnf, features, max_bookings_per_month, max_products, max_staff, analytics_access, display_order)
VALUES 
('basic', 'Basic', 'Pour les petites entreprises', 25000, 270000,
 '["Profil amélioré", "Réservations illimitées", "Gestion clients", "Analytics de base", "Notifications push", "Support email"]'::jsonb,
 50, 15, 3, true, 1);

-- Plan Pro
INSERT INTO public.service_plans (name, display_name, description, monthly_price_gnf, yearly_price_gnf, features, max_bookings_per_month, max_products, max_staff, priority_listing, analytics_access, sms_notifications, display_order)
VALUES 
('pro', 'Professionnel', 'Pour les entreprises en croissance', 75000, 810000,
 '["Listing prioritaire", "Réservations illimitées", "Gestion équipe complète", "Analytics avancés", "SMS notifications", "Support prioritaire", "Promotions", "Multi-services"]'::jsonb,
 NULL, 50, 10, true, true, true, 2);

-- Plan Premium
INSERT INTO public.service_plans (name, display_name, description, monthly_price_gnf, yearly_price_gnf, features, max_bookings_per_month, max_products, max_staff, priority_listing, analytics_access, sms_notifications, custom_branding, api_access, display_order)
VALUES 
('premium', 'Premium', 'Solution complète pour leaders', 150000, 1620000,
 '["Tous les avantages Pro", "Branding personnalisé", "API Access", "Account manager dédié", "Formation dédiée", "Intégrations illimitées", "Rapports personnalisés", "Support 24/7"]'::jsonb,
 NULL, NULL, NULL, true, true, true, true, true, 3);

-- =============================================
-- FONCTIONS RPC
-- =============================================

-- Fonction pour obtenir l'abonnement actif d'un service professionnel
CREATE OR REPLACE FUNCTION public.get_service_subscription(p_service_id UUID)
RETURNS TABLE (
  subscription_id UUID,
  plan_id UUID,
  plan_name TEXT,
  plan_display_name TEXT,
  status TEXT,
  current_period_end TIMESTAMPTZ,
  auto_renew BOOLEAN,
  price_paid INTEGER,
  max_bookings INTEGER,
  max_products INTEGER,
  max_staff INTEGER,
  priority_listing BOOLEAN,
  analytics_access BOOLEAN,
  features JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    ss.id as subscription_id,
    sp.id as plan_id,
    sp.name as plan_name,
    sp.display_name as plan_display_name,
    ss.status,
    ss.current_period_end,
    ss.auto_renew,
    ss.price_paid_gnf as price_paid,
    sp.max_bookings_per_month as max_bookings,
    sp.max_products,
    sp.max_staff,
    sp.priority_listing,
    sp.analytics_access,
    sp.features
  FROM service_subscriptions ss
  JOIN service_plans sp ON ss.plan_id = sp.id
  WHERE ss.professional_service_id = p_service_id
    AND ss.status = 'active'
    AND ss.current_period_end > now()
  ORDER BY ss.created_at DESC
  LIMIT 1;
  
  -- Si aucun abonnement actif, retourner le plan gratuit
  IF NOT FOUND THEN
    RETURN QUERY
    SELECT 
      NULL::UUID as subscription_id,
      sp.id as plan_id,
      sp.name as plan_name,
      sp.display_name as plan_display_name,
      'free'::TEXT as status,
      NULL::TIMESTAMPTZ as current_period_end,
      false as auto_renew,
      0 as price_paid,
      sp.max_bookings_per_month as max_bookings,
      sp.max_products,
      sp.max_staff,
      sp.priority_listing,
      sp.analytics_access,
      sp.features
    FROM service_plans sp
    WHERE sp.name = 'free'
    LIMIT 1;
  END IF;
END;
$$;

-- Fonction pour enregistrer un paiement d'abonnement de service
CREATE OR REPLACE FUNCTION public.record_service_subscription_payment(
  p_user_id UUID,
  p_service_id UUID,
  p_plan_id UUID,
  p_price_paid INTEGER,
  p_payment_method TEXT DEFAULT 'wallet',
  p_payment_transaction_id TEXT DEFAULT NULL,
  p_billing_cycle TEXT DEFAULT 'monthly'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subscription_id UUID;
  v_end_date TIMESTAMPTZ;
  v_wallet_balance INTEGER;
BEGIN
  -- Calculer la date de fin selon le cycle
  IF p_billing_cycle = 'monthly' THEN
    v_end_date := now() + INTERVAL '1 month';
  ELSIF p_billing_cycle = 'yearly' THEN
    v_end_date := now() + INTERVAL '1 year';
  ELSIF p_billing_cycle = 'lifetime' THEN
    v_end_date := now() + INTERVAL '100 years';
  ELSE
    v_end_date := now() + INTERVAL '1 month';
  END IF;
  
  -- Si paiement par wallet, vérifier le solde
  IF p_payment_method = 'wallet' AND p_price_paid > 0 THEN
    SELECT balance INTO v_wallet_balance
    FROM wallets
    WHERE user_id = p_user_id;
    
    IF v_wallet_balance IS NULL OR v_wallet_balance < p_price_paid THEN
      RAISE EXCEPTION 'Solde wallet insuffisant (disponible: %, requis: %)', COALESCE(v_wallet_balance, 0), p_price_paid;
    END IF;
    
    -- Déduire du wallet
    UPDATE wallets
    SET balance = balance - p_price_paid,
        updated_at = now()
    WHERE user_id = p_user_id;
    
    -- Enregistrer la transaction wallet
    INSERT INTO wallet_transactions (wallet_id, type, amount, description, status, metadata)
    SELECT w.id, 'debit', p_price_paid, 'Abonnement service professionnel', 'completed',
           jsonb_build_object('service_id', p_service_id, 'plan_id', p_plan_id)
    FROM wallets w WHERE w.user_id = p_user_id;
  END IF;
  
  -- Annuler les anciens abonnements actifs pour ce service
  UPDATE service_subscriptions
  SET status = 'cancelled',
      cancelled_at = now(),
      updated_at = now()
  WHERE professional_service_id = p_service_id
    AND status = 'active';
  
  -- Créer le nouvel abonnement
  INSERT INTO service_subscriptions (
    professional_service_id,
    user_id,
    plan_id,
    status,
    billing_cycle,
    price_paid_gnf,
    payment_method,
    payment_transaction_id,
    started_at,
    current_period_start,
    current_period_end,
    auto_renew
  ) VALUES (
    p_service_id,
    p_user_id,
    p_plan_id,
    'active',
    p_billing_cycle,
    p_price_paid,
    p_payment_method,
    p_payment_transaction_id,
    now(),
    now(),
    v_end_date,
    p_billing_cycle != 'lifetime'
  )
  RETURNING id INTO v_subscription_id;
  
  -- Enregistrer le paiement
  INSERT INTO service_subscription_payments (
    subscription_id,
    user_id,
    amount_gnf,
    payment_method,
    transaction_reference,
    status
  ) VALUES (
    v_subscription_id,
    p_user_id,
    p_price_paid,
    p_payment_method,
    p_payment_transaction_id,
    'completed'
  );
  
  -- Enregistrer les revenus PDG si la fonction existe
  BEGIN
    PERFORM record_pdg_revenue(
      p_price_paid,
      'service_subscription',
      'Abonnement service professionnel',
      jsonb_build_object('service_id', p_service_id, 'plan_id', p_plan_id, 'subscription_id', v_subscription_id)
    );
  EXCEPTION WHEN undefined_function THEN
    NULL;
  END;
  
  RETURN v_subscription_id;
END;
$$;

-- Fonction pour obtenir les statistiques des abonnements de services
CREATE OR REPLACE FUNCTION public.get_service_subscription_stats()
RETURNS TABLE (
  total_subscriptions BIGINT,
  active_subscriptions BIGINT,
  expired_subscriptions BIGINT,
  total_revenue BIGINT,
  monthly_revenue BIGINT,
  subscriptions_by_plan JSONB,
  subscriptions_by_status JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH stats AS (
    SELECT
      COUNT(*) as total,
      COUNT(*) FILTER (WHERE ss.status = 'active') as active,
      COUNT(*) FILTER (WHERE ss.status = 'expired') as expired,
      COALESCE(SUM(ss.price_paid_gnf), 0) as revenue,
      COALESCE(SUM(ss.price_paid_gnf) FILTER (WHERE ss.created_at > now() - INTERVAL '30 days'), 0) as monthly
    FROM service_subscriptions ss
  ),
  by_plan AS (
    SELECT jsonb_object_agg(
      COALESCE(sp.display_name, 'Unknown'),
      plan_count
    ) as data
    FROM (
      SELECT plan_id, COUNT(*) as plan_count
      FROM service_subscriptions
      GROUP BY plan_id
    ) pc
    LEFT JOIN service_plans sp ON pc.plan_id = sp.id
  ),
  by_status AS (
    SELECT jsonb_object_agg(status, status_count) as data
    FROM (
      SELECT status, COUNT(*) as status_count
      FROM service_subscriptions
      GROUP BY status
    ) sc
  )
  SELECT
    stats.total,
    stats.active,
    stats.expired,
    stats.revenue,
    stats.monthly,
    COALESCE(by_plan.data, '{}'::jsonb),
    COALESCE(by_status.data, '{}'::jsonb)
  FROM stats, by_plan, by_status;
END;
$$;

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION public.update_service_subscription_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = public;

CREATE TRIGGER update_service_subscriptions_updated_at
BEFORE UPDATE ON public.service_subscriptions
FOR EACH ROW
EXECUTE FUNCTION public.update_service_subscription_updated_at();

CREATE TRIGGER update_service_plans_updated_at
BEFORE UPDATE ON public.service_plans
FOR EACH ROW
EXECUTE FUNCTION public.update_service_subscription_updated_at();