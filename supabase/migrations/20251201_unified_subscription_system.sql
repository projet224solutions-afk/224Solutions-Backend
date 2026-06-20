-- ============================================
-- MIGRATION: SYSTÈME D'ABONNEMENT UNIFIÉ
-- Date: 2025-12-01
-- Description: Unification des systèmes d'abonnement vendeurs et chauffeurs/livreurs
-- ============================================

-- ============================================
-- ÉTAPE 1: AJOUTER COLONNES MANQUANTES À LA TABLE PLANS
-- ============================================

-- Ajouter yearly_price_gnf si elle n'existe pas déjà
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name = 'plans' AND column_name = 'yearly_price_gnf') THEN
    ALTER TABLE public.plans ADD COLUMN yearly_price_gnf INTEGER;
  END IF;
END $$;

-- Ajouter yearly_discount_percentage si elle n'existe pas déjà
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name = 'plans' AND column_name = 'yearly_discount_percentage') THEN
    ALTER TABLE public.plans ADD COLUMN yearly_discount_percentage INTEGER DEFAULT 5;
  END IF;
END $$;

-- Ajouter user_role pour spécifier à qui le plan s'applique
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name = 'plans' AND column_name = 'user_role') THEN
    ALTER TABLE public.plans ADD COLUMN user_role TEXT DEFAULT 'vendeur' 
      CHECK (user_role IN ('vendeur', 'taxi', 'livreur', 'all'));
  END IF;
END $$;

-- Ajouter duration_days pour la durée standard
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name = 'plans' AND column_name = 'duration_days') THEN
    ALTER TABLE public.plans ADD COLUMN duration_days INTEGER DEFAULT 30;
  END IF;
END $$;

COMMENT ON COLUMN public.plans.user_role IS 'Role utilisateur: vendeur, taxi, livreur, ou all';
COMMENT ON COLUMN public.plans.duration_days IS 'Durée standard en jours';
COMMENT ON COLUMN public.plans.yearly_price_gnf IS 'Prix annuel en GNF (optionnel)';
COMMENT ON COLUMN public.plans.yearly_discount_percentage IS 'Pourcentage de réduction annuelle';

-- ============================================
-- ÉTAPE 2: CRÉER LES PLANS POUR CHAUFFEURS/LIVREURS
-- ============================================

-- Plan pour Taxi Moto
INSERT INTO public.plans (
  name, 
  display_name, 
  monthly_price_gnf, 
  yearly_price_gnf,
  yearly_discount_percentage,
  user_role,
  duration_days,
  max_products, 
  max_images_per_product, 
  analytics_access, 
  priority_support, 
  featured_products, 
  api_access, 
  custom_branding, 
  display_order, 
  features,
  is_active
) VALUES (
  'taxi_monthly',
  'Abonnement Taxi Moto',
  50000,
  570000,
  5,
  'taxi',
  30,
  NULL,
  NULL,
  true,
  false,
  false,
  false,
  false,
  10,
  '["Accès illimité aux courses", "Notification en temps réel", "Historique des trajets", "Support client 24/7", "Tableau de bord chauffeur"]'::jsonb,
  true
) ON CONFLICT (name) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  monthly_price_gnf = EXCLUDED.monthly_price_gnf,
  yearly_price_gnf = EXCLUDED.yearly_price_gnf,
  yearly_discount_percentage = EXCLUDED.yearly_discount_percentage,
  user_role = EXCLUDED.user_role,
  duration_days = EXCLUDED.duration_days,
  features = EXCLUDED.features,
  is_active = EXCLUDED.is_active,
  updated_at = NOW();

-- Plan pour Livreur
INSERT INTO public.plans (
  name, 
  display_name, 
  monthly_price_gnf, 
  yearly_price_gnf,
  yearly_discount_percentage,
  user_role,
  duration_days,
  max_products, 
  max_images_per_product, 
  analytics_access, 
  priority_support, 
  featured_products, 
  api_access, 
  custom_branding, 
  display_order, 
  features,
  is_active
) VALUES (
  'livreur_monthly',
  'Abonnement Livreur',
  50000,
  570000,
  5,
  'livreur',
  30,
  NULL,
  NULL,
  true,
  false,
  false,
  false,
  false,
  11,
  '["Accès illimité aux livraisons", "Notification en temps réel", "Historique des livraisons", "Support client 24/7", "Tableau de bord livreur"]'::jsonb,
  true
) ON CONFLICT (name) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  monthly_price_gnf = EXCLUDED.monthly_price_gnf,
  yearly_price_gnf = EXCLUDED.yearly_price_gnf,
  yearly_discount_percentage = EXCLUDED.yearly_discount_percentage,
  user_role = EXCLUDED.user_role,
  duration_days = EXCLUDED.duration_days,
  features = EXCLUDED.features,
  is_active = EXCLUDED.is_active,
  updated_at = NOW();

-- ============================================
-- ÉTAPE 3: MIGRER LES ABONNEMENTS CHAUFFEURS/LIVREURS EXISTANTS
-- ============================================

-- Créer une fonction pour migrer les abonnements driver vers subscriptions
CREATE OR REPLACE FUNCTION migrate_driver_subscriptions_to_unified()
RETURNS TABLE (migrated_count INTEGER) AS $$
DECLARE
  v_taxi_plan_id UUID;
  v_livreur_plan_id UUID;
  v_count INTEGER := 0;
BEGIN
  -- Récupérer les IDs des plans
  SELECT id INTO v_taxi_plan_id FROM public.plans WHERE name = 'taxi_monthly';
  SELECT id INTO v_livreur_plan_id FROM public.plans WHERE name = 'livreur_monthly';
  
  -- Migrer les abonnements actifs des taxis
  INSERT INTO public.subscriptions (
    user_id,
    plan_id,
    price_paid_gnf,
    billing_cycle,
    status,
    started_at,
    current_period_end,
    auto_renew,
    payment_method,
    payment_transaction_id,
    metadata,
    created_at,
    updated_at
  )
  SELECT 
    ds.user_id,
    v_taxi_plan_id,
    ds.price::INTEGER,
    CASE 
      WHEN ds.billing_cycle = 'yearly' THEN 'yearly'
      ELSE 'monthly'
    END,
    CASE 
      WHEN ds.status = 'active' AND ds.end_date > NOW() THEN 'active'
      WHEN ds.status = 'expired' OR ds.end_date <= NOW() THEN 'expired'
      WHEN ds.status = 'suspended' THEN 'cancelled'
      ELSE 'expired'
    END,
    ds.start_date,
    ds.end_date,
    true,
    ds.payment_method,
    ds.transaction_id,
    ds.metadata,
    ds.created_at,
    ds.updated_at
  FROM driver_subscriptions ds
  WHERE ds.type = 'taxi'
    AND NOT EXISTS (
      SELECT 1 FROM public.subscriptions s 
      WHERE s.user_id = ds.user_id 
        AND s.plan_id = v_taxi_plan_id
        AND s.created_at = ds.created_at
    );
  
  GET DIAGNOSTICS v_count = ROW_COUNT;
  
  -- Migrer les abonnements actifs des livreurs
  INSERT INTO public.subscriptions (
    user_id,
    plan_id,
    price_paid_gnf,
    billing_cycle,
    status,
    started_at,
    current_period_end,
    auto_renew,
    payment_method,
    payment_transaction_id,
    metadata,
    created_at,
    updated_at
  )
  SELECT 
    ds.user_id,
    v_livreur_plan_id,
    ds.price::INTEGER,
    CASE 
      WHEN ds.billing_cycle = 'yearly' THEN 'yearly'
      ELSE 'monthly'
    END,
    CASE 
      WHEN ds.status = 'active' AND ds.end_date > NOW() THEN 'active'
      WHEN ds.status = 'expired' OR ds.end_date <= NOW() THEN 'expired'
      WHEN ds.status = 'suspended' THEN 'cancelled'
      ELSE 'expired'
    END,
    ds.start_date,
    ds.end_date,
    true,
    ds.payment_method,
    ds.transaction_id,
    ds.metadata,
    ds.created_at,
    ds.updated_at
  FROM driver_subscriptions ds
  WHERE ds.type = 'livreur'
    AND NOT EXISTS (
      SELECT 1 FROM public.subscriptions s 
      WHERE s.user_id = ds.user_id 
        AND s.plan_id = v_livreur_plan_id
        AND s.created_at = ds.created_at
    );
  
  GET DIAGNOSTICS v_count = v_count + ROW_COUNT;
  
  RETURN QUERY SELECT v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Exécuter la migration
SELECT migrate_driver_subscriptions_to_unified();

-- ============================================
-- ÉTAPE 4: METTRE À JOUR LA FONCTION get_active_subscription
-- ============================================

-- Fonction universelle pour récupérer l'abonnement actif (tous rôles)
CREATE OR REPLACE FUNCTION public.get_active_subscription(p_user_id UUID)
RETURNS TABLE (
  subscription_id UUID,
  plan_id UUID,
  plan_name VARCHAR,
  plan_display_name VARCHAR,
  status VARCHAR,
  current_period_end TIMESTAMP WITH TIME ZONE,
  auto_renew BOOLEAN,
  price_paid INTEGER,
  billing_cycle VARCHAR,
  user_role TEXT,
  duration_days INTEGER,
  max_products INTEGER,
  max_images_per_product INTEGER,
  analytics_access BOOLEAN,
  priority_support BOOLEAN,
  featured_products BOOLEAN,
  api_access BOOLEAN,
  custom_branding BOOLEAN,
  features JSONB
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    s.id as subscription_id,
    p.id as plan_id,
    p.name as plan_name,
    p.display_name as plan_display_name,
    s.status,
    s.current_period_end,
    s.auto_renew,
    s.price_paid_gnf as price_paid,
    s.billing_cycle,
    p.user_role,
    p.duration_days,
    p.max_products,
    p.max_images_per_product,
    p.analytics_access,
    p.priority_support,
    p.featured_products,
    p.api_access,
    p.custom_branding,
    p.features
  FROM public.subscriptions s
  INNER JOIN public.plans p ON s.plan_id = p.id
  WHERE s.user_id = p_user_id
    AND s.status = 'active'
    AND s.current_period_end > NOW()
  ORDER BY s.current_period_end DESC
  LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- ÉTAPE 5: FONCTION POUR VÉRIFIER L'ACCÈS (Tous rôles)
-- ============================================

CREATE OR REPLACE FUNCTION public.has_active_subscription(p_user_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.subscriptions
    WHERE user_id = p_user_id
      AND status = 'active'
      AND current_period_end > NOW()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- ÉTAPE 6: FONCTION UNIVERSELLE POUR SOUSCRIRE
-- ============================================

CREATE OR REPLACE FUNCTION public.subscribe_user(
  p_user_id UUID,
  p_plan_id UUID,
  p_payment_method TEXT DEFAULT 'wallet',
  p_transaction_id TEXT DEFAULT NULL,
  p_billing_cycle TEXT DEFAULT 'monthly'
)
RETURNS UUID AS $$
DECLARE
  v_subscription_id UUID;
  v_price INTEGER;
  v_duration_days INTEGER;
  v_period_end TIMESTAMP WITH TIME ZONE;
  v_plan_name TEXT;
  v_user_role TEXT;
BEGIN
  -- Récupérer les infos du plan
  SELECT 
    CASE 
      WHEN p_billing_cycle = 'yearly' THEN COALESCE(yearly_price_gnf, monthly_price_gnf * 12)
      ELSE monthly_price_gnf 
    END,
    CASE 
      WHEN p_billing_cycle = 'yearly' THEN duration_days * 12
      ELSE duration_days 
    END,
    name,
    user_role
  INTO v_price, v_duration_days, v_plan_name, v_user_role
  FROM public.plans
  WHERE id = p_plan_id AND is_active = true;
  
  IF v_price IS NULL THEN
    RAISE EXCEPTION 'Plan non trouvé ou inactif';
  END IF;
  
  -- Calculer la date de fin
  v_period_end := NOW() + (v_duration_days || ' days')::INTERVAL;
  
  -- Désactiver les anciens abonnements de l'utilisateur
  UPDATE public.subscriptions 
  SET status = 'cancelled', 
      auto_renew = false,
      updated_at = NOW()
  WHERE user_id = p_user_id 
    AND status = 'active';
  
  -- Créer le nouvel abonnement
  INSERT INTO public.subscriptions (
    user_id,
    plan_id,
    price_paid_gnf,
    billing_cycle,
    status,
    current_period_end,
    payment_method,
    payment_transaction_id,
    metadata
  ) VALUES (
    p_user_id,
    p_plan_id,
    v_price,
    p_billing_cycle,
    'active',
    v_period_end,
    p_payment_method,
    p_transaction_id,
    jsonb_build_object('migrated', false, 'plan_type', v_user_role)
  )
  RETURNING id INTO v_subscription_id;
  
  -- Enregistrer le revenu PDG (100% du montant)
  INSERT INTO public.revenus_pdg (
    source_type,
    transaction_id,
    user_id,
    amount,
    description,
    metadata
  ) VALUES (
    'frais_abonnement',
    v_subscription_id,
    p_user_id,
    v_price,
    'Abonnement ' || v_plan_name || ' (' || p_billing_cycle || ')',
    jsonb_build_object(
      'subscription_id', v_subscription_id,
      'plan_id', p_plan_id,
      'plan_name', v_plan_name,
      'billing_cycle', p_billing_cycle,
      'user_role', v_user_role
    )
  );
  
  RETURN v_subscription_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- ÉTAPE 7: FONCTION POUR OBTENIR LES PLANS PAR RÔLE
-- ============================================

CREATE OR REPLACE FUNCTION public.get_plans_for_role(p_role TEXT DEFAULT NULL)
RETURNS TABLE (
  id UUID,
  name VARCHAR,
  display_name VARCHAR,
  monthly_price_gnf INTEGER,
  yearly_price_gnf INTEGER,
  yearly_discount_percentage INTEGER,
  user_role TEXT,
  duration_days INTEGER,
  max_products INTEGER,
  max_images_per_product INTEGER,
  analytics_access BOOLEAN,
  priority_support BOOLEAN,
  featured_products BOOLEAN,
  api_access BOOLEAN,
  custom_branding BOOLEAN,
  features JSONB,
  is_active BOOLEAN,
  display_order INTEGER
) AS $$
BEGIN
  IF p_role IS NULL THEN
    -- Retourner tous les plans actifs
    RETURN QUERY
    SELECT 
      p.id, p.name, p.display_name, p.monthly_price_gnf, p.yearly_price_gnf,
      p.yearly_discount_percentage, p.user_role, p.duration_days,
      p.max_products, p.max_images_per_product, p.analytics_access,
      p.priority_support, p.featured_products, p.api_access,
      p.custom_branding, p.features, p.is_active, p.display_order
    FROM public.plans p
    WHERE p.is_active = true
    ORDER BY p.display_order;
  ELSE
    -- Retourner les plans pour le rôle spécifique ou 'all'
    RETURN QUERY
    SELECT 
      p.id, p.name, p.display_name, p.monthly_price_gnf, p.yearly_price_gnf,
      p.yearly_discount_percentage, p.user_role, p.duration_days,
      p.max_products, p.max_images_per_product, p.analytics_access,
      p.priority_support, p.featured_products, p.api_access,
      p.custom_branding, p.features, p.is_active, p.display_order
    FROM public.plans p
    WHERE p.is_active = true
      AND (p.user_role = p_role OR p.user_role = 'all')
    ORDER BY p.display_order;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- ÉTAPE 8: METTRE À JOUR record_subscription_payment
-- ============================================

DROP FUNCTION IF EXISTS public.record_subscription_payment(UUID, UUID, INTEGER, VARCHAR, UUID, VARCHAR);

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
BEGIN
  -- Utiliser la nouvelle fonction universelle
  RETURN subscribe_user(
    p_user_id,
    p_plan_id,
    p_payment_method,
    p_payment_transaction_id::TEXT,
    p_billing_cycle
  );
END;
$$;

-- ============================================
-- ÉTAPE 9: METTRE À JOUR LES PRIX ANNUELS DES PLANS EXISTANTS
-- ============================================

UPDATE public.plans
SET 
  yearly_price_gnf = ROUND(monthly_price_gnf * 12 * 0.95),
  yearly_discount_percentage = 5,
  duration_days = 30
WHERE yearly_price_gnf IS NULL
  AND monthly_price_gnf > 0;

-- ============================================
-- ÉTAPE 10: FONCTION POUR MARQUER LES ABONNEMENTS EXPIRÉS (Unifié)
-- ============================================

CREATE OR REPLACE FUNCTION public.mark_expired_subscriptions()
RETURNS INTEGER AS $$
DECLARE
  v_count INTEGER;
BEGIN
  UPDATE public.subscriptions
  SET status = 'expired', 
      updated_at = NOW()
  WHERE status = 'active' 
    AND current_period_end < NOW();
  
  GET DIAGNOSTICS v_count = ROW_COUNT;
  
  RETURN COALESCE(v_count, 0);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- ÉTAPE 11: VUES POUR COMPATIBILITÉ AVEC L'ANCIEN SYSTÈME
-- ============================================

-- Vue pour maintenir la compatibilité avec driver_subscriptions
CREATE OR REPLACE VIEW public.driver_subscriptions_view AS
SELECT 
  s.id,
  s.user_id,
  CASE 
    WHEN p.user_role = 'taxi' THEN 'taxi'
    WHEN p.user_role = 'livreur' THEN 'livreur'
    ELSE 'taxi'
  END as type,
  s.price_paid_gnf::NUMERIC as price,
  s.status,
  s.started_at as start_date,
  s.current_period_end as end_date,
  s.payment_method,
  s.payment_transaction_id as transaction_id,
  s.metadata,
  s.created_at,
  s.updated_at,
  s.billing_cycle,
  EXTRACT(DAY FROM (s.current_period_end - NOW()))::INTEGER as days_remaining
FROM public.subscriptions s
INNER JOIN public.plans p ON s.plan_id = p.id
WHERE p.user_role IN ('taxi', 'livreur');

-- ============================================
-- ÉTAPE 12: GRANT PERMISSIONS
-- ============================================

GRANT EXECUTE ON FUNCTION public.get_active_subscription(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_active_subscription(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.subscribe_user(UUID, UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_plans_for_role(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_subscription_payment(UUID, UUID, INTEGER, VARCHAR, UUID, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_expired_subscriptions() TO authenticated;

GRANT SELECT ON public.driver_subscriptions_view TO authenticated;

-- ============================================
-- ÉTAPE 13: COMMENTAIRES
-- ============================================

COMMENT ON FUNCTION public.get_active_subscription(UUID) IS 'Récupère l''abonnement actif d''un utilisateur (tous rôles)';
COMMENT ON FUNCTION public.has_active_subscription(UUID) IS 'Vérifie si l''utilisateur a un abonnement actif';
COMMENT ON FUNCTION public.subscribe_user(UUID, UUID, TEXT, TEXT, TEXT) IS 'Fonction universelle pour souscrire à un plan (tous rôles)';
COMMENT ON FUNCTION public.get_plans_for_role(TEXT) IS 'Récupère les plans disponibles pour un rôle spécifique';
COMMENT ON FUNCTION public.mark_expired_subscriptions() IS 'Marque les abonnements expirés (tous rôles)';
COMMENT ON VIEW public.driver_subscriptions_view IS 'Vue de compatibilité pour l''ancien système driver_subscriptions';

-- ============================================
-- FIN DE LA MIGRATION
-- ============================================

-- Message de confirmation
DO $$
BEGIN
  RAISE NOTICE '✅ Migration vers système d''abonnement unifié terminée avec succès';
  RAISE NOTICE '📊 Tables unifiées: plans + subscriptions';
  RAISE NOTICE '🔄 Anciennes données migrées vers le nouveau système';
  RAISE NOTICE '👥 Support: vendeur, taxi, livreur dans une seule table';
END $$;
