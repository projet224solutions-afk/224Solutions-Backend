-- Ajouter le support des abonnements annuels pour les drivers (taxi/livreur)
-- Ajout d'une colonne duration_type à driver_subscription_config
ALTER TABLE public.driver_subscription_config 
ADD COLUMN IF NOT EXISTS duration_type TEXT DEFAULT 'monthly' CHECK (duration_type IN ('monthly', 'yearly'));

-- Ajout d'une colonne yearly_price avec réduction de 5%
ALTER TABLE public.driver_subscription_config
ADD COLUMN IF NOT EXISTS yearly_price NUMERIC(10,2);

-- Ajout d'une colonne discount_percentage pour les abonnements annuels
ALTER TABLE public.driver_subscription_config
ADD COLUMN IF NOT EXISTS yearly_discount_percentage NUMERIC(5,2) DEFAULT 5.00;

-- Mise à jour de la configuration existante pour calculer le prix annuel avec réduction
UPDATE public.driver_subscription_config
SET yearly_price = ROUND(price * 12 * 0.95, 2),
    yearly_discount_percentage = 5.00
WHERE yearly_price IS NULL;

-- Ajouter une colonne billing_cycle à driver_subscriptions pour suivre le type d'abonnement
ALTER TABLE public.driver_subscriptions
ADD COLUMN IF NOT EXISTS billing_cycle TEXT DEFAULT 'monthly' CHECK (billing_cycle IN ('monthly', 'yearly'));

-- Mettre à jour la fonction subscribe_driver pour supporter les abonnements annuels
CREATE OR REPLACE FUNCTION public.subscribe_driver(
  p_user_id UUID,
  p_type TEXT,
  p_payment_method TEXT,
  p_transaction_id TEXT,
  p_billing_cycle TEXT DEFAULT 'monthly'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_config RECORD;
  v_subscription_id UUID;
  v_start_date TIMESTAMPTZ;
  v_end_date TIMESTAMPTZ;
  v_duration_days INTEGER;
  v_price NUMERIC(10,2);
BEGIN
  -- Récupérer la configuration
  SELECT * INTO v_config
  FROM driver_subscription_config
  WHERE subscription_type = 'both' AND is_active = true
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Configuration d''abonnement non trouvée';
  END IF;

  -- Déterminer le prix et la durée selon le cycle de facturation
  IF p_billing_cycle = 'yearly' THEN
    v_price := COALESCE(v_config.yearly_price, v_config.price * 12 * 0.95);
    v_duration_days := 365;
  ELSE
    v_price := v_config.price;
    v_duration_days := v_config.duration_days;
  END IF;

  v_start_date := NOW();
  v_end_date := v_start_date + (v_duration_days || ' days')::INTERVAL;

  -- Désactiver les anciens abonnements actifs
  UPDATE driver_subscriptions
  SET status = 'expired', updated_at = NOW()
  WHERE user_id = p_user_id 
    AND status = 'active';

  -- Créer le nouvel abonnement
  INSERT INTO driver_subscriptions (
    user_id, 
    type, 
    price, 
    status, 
    start_date, 
    end_date,
    payment_method,
    transaction_id,
    billing_cycle,
    created_at,
    updated_at
  ) VALUES (
    p_user_id,
    p_type,
    v_price,
    'active',
    v_start_date,
    v_end_date,
    p_payment_method,
    p_transaction_id,
    p_billing_cycle,
    NOW(),
    NOW()
  )
  RETURNING id INTO v_subscription_id;

  -- Enregistrer les revenus
  INSERT INTO driver_subscription_revenues (
    subscription_id,
    user_id,
    amount,
    payment_method,
    transaction_id,
    created_at
  ) VALUES (
    v_subscription_id,
    p_user_id,
    v_price,
    p_payment_method,
    p_transaction_id,
    NOW()
  );

  RETURN v_subscription_id;
END;
$$;

-- Ajouter des colonnes pour les abonnements annuels dans la table plans (vendeurs)
ALTER TABLE public.plans
ADD COLUMN IF NOT EXISTS yearly_price_gnf NUMERIC(10,2);

ALTER TABLE public.plans
ADD COLUMN IF NOT EXISTS yearly_discount_percentage NUMERIC(5,2) DEFAULT 5.00;

-- Calculer les prix annuels avec réduction de 5% pour les plans existants
UPDATE public.plans
SET yearly_price_gnf = ROUND(monthly_price_gnf * 12 * 0.95, 2),
    yearly_discount_percentage = 5.00
WHERE yearly_price_gnf IS NULL;

-- Ajouter une colonne billing_cycle à subscriptions pour les vendeurs
ALTER TABLE public.subscriptions
ADD COLUMN IF NOT EXISTS billing_cycle TEXT DEFAULT 'monthly' CHECK (billing_cycle IN ('monthly', 'yearly'));

-- Commentaires pour documentation
COMMENT ON COLUMN public.driver_subscription_config.duration_type IS 'Type de durée: monthly ou yearly';
COMMENT ON COLUMN public.driver_subscription_config.yearly_price IS 'Prix annuel avec réduction de 5%';
COMMENT ON COLUMN public.driver_subscription_config.yearly_discount_percentage IS 'Pourcentage de réduction pour abonnement annuel';
COMMENT ON COLUMN public.driver_subscriptions.billing_cycle IS 'Cycle de facturation: monthly ou yearly';
COMMENT ON COLUMN public.plans.yearly_price_gnf IS 'Prix annuel en GNF avec réduction de 5%';
COMMENT ON COLUMN public.plans.yearly_discount_percentage IS 'Pourcentage de réduction pour abonnement annuel';
COMMENT ON COLUMN public.subscriptions.billing_cycle IS 'Cycle de facturation: monthly ou yearly';