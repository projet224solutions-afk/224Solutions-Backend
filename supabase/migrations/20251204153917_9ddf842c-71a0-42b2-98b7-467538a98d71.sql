-- Drop ALL existing versions of the function to avoid conflicts
DROP FUNCTION IF EXISTS public.record_subscription_payment(UUID, UUID, INTEGER, VARCHAR, UUID, VARCHAR);
DROP FUNCTION IF EXISTS public.record_subscription_payment(UUID, UUID, NUMERIC, VARCHAR, VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS public.record_subscription_payment(UUID, UUID, NUMERIC, VARCHAR, TEXT, VARCHAR);

-- Recreate single clean version
CREATE OR REPLACE FUNCTION public.record_subscription_payment(
  p_user_id UUID,
  p_plan_id UUID,
  p_price_paid NUMERIC,
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
  v_period_end TIMESTAMP WITH TIME ZONE;
  v_plan_name VARCHAR;
BEGIN
  -- Calculer la date de fin de période selon le cycle de facturation
  IF p_billing_cycle = 'yearly' THEN
    v_period_end := now() + INTERVAL '1 year';
  ELSIF p_billing_cycle = 'quarterly' THEN
    v_period_end := now() + INTERVAL '3 months';
  ELSE
    -- monthly par défaut
    v_period_end := now() + INTERVAL '1 month';
  END IF;
  
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