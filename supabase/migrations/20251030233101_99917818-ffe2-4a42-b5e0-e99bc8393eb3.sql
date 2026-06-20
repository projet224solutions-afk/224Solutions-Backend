-- ============================================
-- MIGRATION: Système d'abonnements vendeur
-- ============================================

-- 1. Créer la table plans
CREATE TABLE IF NOT EXISTS public.plans (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  name VARCHAR(50) NOT NULL UNIQUE,
  display_name VARCHAR(100) NOT NULL,
  monthly_price_gnf INTEGER NOT NULL,
  max_products INTEGER NULL, -- NULL = illimité
  max_images_per_product INTEGER NULL,
  analytics_access BOOLEAN DEFAULT false,
  priority_support BOOLEAN DEFAULT false,
  featured_products BOOLEAN DEFAULT false,
  api_access BOOLEAN DEFAULT false,
  custom_branding BOOLEAN DEFAULT false,
  features JSONB DEFAULT '[]'::jsonb,
  is_active BOOLEAN DEFAULT true,
  display_order INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 2. Créer la table subscriptions
CREATE TABLE IF NOT EXISTS public.subscriptions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  plan_id UUID NOT NULL REFERENCES public.plans(id),
  price_paid_gnf INTEGER NOT NULL,
  billing_cycle VARCHAR(20) DEFAULT 'monthly',
  status VARCHAR(20) NOT NULL DEFAULT 'active',
  started_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  current_period_end TIMESTAMP WITH TIME ZONE NOT NULL,
  auto_renew BOOLEAN DEFAULT true,
  payment_method VARCHAR(50),
  payment_transaction_id UUID NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  CONSTRAINT valid_status CHECK (status IN ('active','past_due','cancelled','trialing','expired'))
);

-- 3. Créer la table plan_price_history
CREATE TABLE IF NOT EXISTS public.plan_price_history (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  plan_id UUID NOT NULL REFERENCES public.plans(id),
  old_price INTEGER NOT NULL,
  new_price INTEGER NOT NULL,
  changed_by UUID NOT NULL REFERENCES auth.users(id),
  reason TEXT,
  changed_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 4. Mettre à jour l'ENUM source_type dans revenus_pdg si nécessaire
-- D'abord vérifier si le type existe et ajouter 'frais_abonnement' s'il n'existe pas
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum 
    WHERE enumlabel = 'frais_abonnement' 
    AND enumtypid = (SELECT oid FROM pg_type WHERE typname = 'revenus_pdg_source_type')
  ) THEN
    ALTER TYPE revenus_pdg_source_type ADD VALUE 'frais_abonnement';
  END IF;
EXCEPTION
  WHEN undefined_object THEN
    -- Le type n'existe pas, modifier la colonne
    ALTER TABLE public.revenus_pdg 
    ALTER COLUMN source_type TYPE TEXT;
END $$;

-- 5. Créer index pour performance
CREATE INDEX IF NOT EXISTS idx_subscriptions_user_id ON public.subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_status ON public.subscriptions(status);
CREATE INDEX IF NOT EXISTS idx_subscriptions_period_end ON public.subscriptions(current_period_end);
CREATE INDEX IF NOT EXISTS idx_plans_name ON public.plans(name);
CREATE INDEX IF NOT EXISTS idx_plan_price_history_plan_id ON public.plan_price_history(plan_id);

-- 6. Activer RLS sur les nouvelles tables
ALTER TABLE public.plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plan_price_history ENABLE ROW LEVEL SECURITY;

-- 7. Politiques RLS pour plans
CREATE POLICY "Everyone can view active plans"
  ON public.plans FOR SELECT
  USING (is_active = true);

CREATE POLICY "Admins can manage plans"
  ON public.plans FOR ALL
  USING (has_role(auth.uid(), 'admin'::user_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::user_role));

-- 8. Politiques RLS pour subscriptions
CREATE POLICY "Users can view their own subscriptions"
  ON public.subscriptions FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own subscriptions"
  ON public.subscriptions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Admins can view all subscriptions"
  ON public.subscriptions FOR SELECT
  USING (has_role(auth.uid(), 'admin'::user_role));

CREATE POLICY "Admins can manage all subscriptions"
  ON public.subscriptions FOR ALL
  USING (has_role(auth.uid(), 'admin'::user_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::user_role));

CREATE POLICY "Service role full access to subscriptions"
  ON public.subscriptions FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- 9. Politiques RLS pour plan_price_history
CREATE POLICY "Admins can view price history"
  ON public.plan_price_history FOR SELECT
  USING (has_role(auth.uid(), 'admin'::user_role));

CREATE POLICY "Admins can insert price history"
  ON public.plan_price_history FOR INSERT
  WITH CHECK (has_role(auth.uid(), 'admin'::user_role));

-- 10. Insérer les plans par défaut
INSERT INTO public.plans (name, display_name, monthly_price_gnf, max_products, max_images_per_product, analytics_access, priority_support, featured_products, api_access, custom_branding, display_order, features) VALUES
('free', 'Gratuit', 0, 5, 3, false, false, false, false, false, 0, 
  '["5 produits max", "3 images par produit", "Support communautaire", "Tableau de bord basique"]'::jsonb),
('basic', 'Basic', 15000, 20, 5, true, false, false, false, false, 1,
  '["20 produits", "5 images par produit", "Analytics basiques", "Support email", "Statistiques de ventes"]'::jsonb),
('pro', 'Pro', 50000, 100, 10, true, true, true, false, false, 2,
  '["100 produits", "10 images par produit", "Analytics avancés", "Support prioritaire", "Produits en vedette", "Promotions personnalisées"]'::jsonb),
('business', 'Business', 100000, 500, 15, true, true, true, true, false, 3,
  '["500 produits", "15 images par produit", "Analytics complets", "Support dédié", "API access", "Intégrations avancées", "Exports de données"]'::jsonb),
('premium', 'Premium', 200000, NULL, 20, true, true, true, true, true, 4,
  '["Produits illimités", "20 images par produit", "Analytics en temps réel", "Account manager", "API premium", "Branding personnalisé", "Formation dédiée", "Priorité absolue"]'::jsonb)
ON CONFLICT (name) DO NOTHING;

-- 11. Fonction pour enregistrer un paiement d'abonnement
CREATE OR REPLACE FUNCTION public.record_subscription_payment(
  p_user_id UUID,
  p_plan_id UUID,
  p_price_paid INTEGER,
  p_payment_method VARCHAR DEFAULT 'wallet',
  p_payment_transaction_id UUID DEFAULT NULL,
  p_billing_cycle VARCHAR DEFAULT 'monthly'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_subscription_id UUID;
  v_period_end TIMESTAMP WITH TIME ZONE;
  v_plan_name VARCHAR;
BEGIN
  -- Calculer la date de fin de période (30 jours)
  v_period_end := now() + INTERVAL '30 days';
  
  -- Récupérer le nom du plan pour les revenus PDG
  SELECT name INTO v_plan_name FROM public.plans WHERE id = p_plan_id;
  
  -- Désactiver les anciennes souscriptions de l'utilisateur
  UPDATE public.subscriptions 
  SET status = 'cancelled', 
      auto_renew = false,
      updated_at = now()
  WHERE user_id = p_user_id 
    AND status = 'active';
  
  -- Créer la nouvelle souscription
  INSERT INTO public.subscriptions (
    user_id,
    plan_id,
    price_paid_gnf,
    billing_cycle,
    status,
    current_period_end,
    payment_method,
    payment_transaction_id
  ) VALUES (
    p_user_id,
    p_plan_id,
    p_price_paid,
    p_billing_cycle,
    'active',
    v_period_end,
    p_payment_method,
    p_payment_transaction_id
  )
  RETURNING id INTO v_subscription_id;
  
  -- Enregistrer le revenu PDG (100% du montant)
  INSERT INTO public.revenus_pdg (
    source_type,
    transaction_id,
    user_id,
    amount,
    percentage_applied,
    metadata
  ) VALUES (
    'frais_abonnement',
    p_payment_transaction_id,
    p_user_id,
    p_price_paid,
    100.00,
    jsonb_build_object(
      'subscription_id', v_subscription_id,
      'plan_name', v_plan_name,
      'billing_cycle', p_billing_cycle
    )
  );
  
  RETURN v_subscription_id;
END;
$$;

-- 12. Fonction pour changer le prix d'un plan
CREATE OR REPLACE FUNCTION public.change_plan_price(
  p_plan_id UUID,
  p_new_price INTEGER,
  p_admin_user_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_old_price INTEGER;
BEGIN
  -- Vérifier que l'utilisateur est admin
  IF NOT has_role(p_admin_user_id, 'admin'::user_role) THEN
    RAISE EXCEPTION 'Unauthorized: Only admins can change plan prices';
  END IF;
  
  -- Récupérer l'ancien prix
  SELECT monthly_price_gnf INTO v_old_price
  FROM public.plans
  WHERE id = p_plan_id;
  
  IF v_old_price IS NULL THEN
    RAISE EXCEPTION 'Plan not found';
  END IF;
  
  -- Enregistrer dans l'historique
  INSERT INTO public.plan_price_history (
    plan_id,
    old_price,
    new_price,
    changed_by,
    reason
  ) VALUES (
    p_plan_id,
    v_old_price,
    p_new_price,
    p_admin_user_id,
    p_reason
  );
  
  -- Mettre à jour le prix
  UPDATE public.plans
  SET monthly_price_gnf = p_new_price,
      updated_at = now()
  WHERE id = p_plan_id;
  
  RETURN true;
END;
$$;

-- 13. Fonction pour vérifier les limites de produits
CREATE OR REPLACE FUNCTION public.check_product_limit(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_current_count INTEGER;
  v_max_products INTEGER;
  v_plan_name VARCHAR;
  v_result JSONB;
BEGIN
  -- Récupérer le plan actif de l'utilisateur
  SELECT p.max_products, p.name
  INTO v_max_products, v_plan_name
  FROM public.subscriptions s
  JOIN public.plans p ON s.plan_id = p.id
  WHERE s.user_id = p_user_id
    AND s.status = 'active'
    AND s.current_period_end > now()
  ORDER BY s.created_at DESC
  LIMIT 1;
  
  -- Si pas d'abonnement, utiliser le plan gratuit
  IF v_max_products IS NULL THEN
    SELECT max_products, name
    INTO v_max_products, v_plan_name
    FROM public.plans
    WHERE name = 'free';
  END IF;
  
  -- Compter les produits de l'utilisateur
  SELECT COUNT(*)
  INTO v_current_count
  FROM public.products
  WHERE vendor_id IN (
    SELECT id FROM public.vendors WHERE user_id = p_user_id
  );
  
  -- Construire le résultat
  v_result := jsonb_build_object(
    'current_count', v_current_count,
    'max_products', v_max_products,
    'plan_name', v_plan_name,
    'can_add', (v_max_products IS NULL OR v_current_count < v_max_products),
    'is_unlimited', (v_max_products IS NULL)
  );
  
  RETURN v_result;
END;
$$;

-- 14. Fonction pour obtenir l'abonnement actif d'un utilisateur
CREATE OR REPLACE FUNCTION public.get_active_subscription(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'subscription_id', s.id,
    'plan_id', s.plan_id,
    'plan_name', p.name,
    'plan_display_name', p.display_name,
    'status', s.status,
    'current_period_end', s.current_period_end,
    'auto_renew', s.auto_renew,
    'price_paid', s.price_paid_gnf,
    'max_products', p.max_products,
    'max_images_per_product', p.max_images_per_product,
    'analytics_access', p.analytics_access,
    'priority_support', p.priority_support,
    'featured_products', p.featured_products,
    'api_access', p.api_access,
    'custom_branding', p.custom_branding,
    'features', p.features
  )
  INTO v_result
  FROM public.subscriptions s
  JOIN public.plans p ON s.plan_id = p.id
  WHERE s.user_id = p_user_id
    AND s.status = 'active'
    AND s.current_period_end > now()
  ORDER BY s.created_at DESC
  LIMIT 1;
  
  -- Si pas d'abonnement actif, retourner le plan gratuit
  IF v_result IS NULL THEN
    SELECT jsonb_build_object(
      'subscription_id', NULL,
      'plan_id', p.id,
      'plan_name', p.name,
      'plan_display_name', p.display_name,
      'status', 'free',
      'current_period_end', NULL,
      'auto_renew', false,
      'price_paid', 0,
      'max_products', p.max_products,
      'max_images_per_product', p.max_images_per_product,
      'analytics_access', p.analytics_access,
      'priority_support', p.priority_support,
      'featured_products', p.featured_products,
      'api_access', p.api_access,
      'custom_branding', p.custom_branding,
      'features', p.features
    )
    INTO v_result
    FROM public.plans p
    WHERE p.name = 'free';
  END IF;
  
  RETURN v_result;
END;
$$;

-- 15. Trigger pour updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_plans_updated_at
  BEFORE UPDATE ON public.plans
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_subscriptions_updated_at
  BEFORE UPDATE ON public.subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();