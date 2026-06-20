-- Fonction RPC pour permettre au PDG d'offrir un abonnement à un conducteur
-- Utilise SECURITY DEFINER pour bypasser les RLS policies

CREATE OR REPLACE FUNCTION public.pdg_offer_subscription(
  p_user_id UUID,
  p_type TEXT,
  p_days INTEGER
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subscription_id UUID;
  v_start_date TIMESTAMPTZ;
  v_end_date TIMESTAMPTZ;
  v_user_exists BOOLEAN;
  v_user_email TEXT;
BEGIN
  -- Validation du type
  IF p_type NOT IN ('taxi', 'livreur') THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Type invalide. Utilisez "taxi" ou "livreur".'
    );
  END IF;

  -- Validation des jours
  IF p_days <= 0 OR p_days > 365 THEN
    RETURN json_build_object(
      'success', false,
      'error', 'La durée doit être entre 1 et 365 jours.'
    );
  END IF;

  -- Vérifier que l'utilisateur existe
  SELECT EXISTS(SELECT 1 FROM auth.users WHERE id = p_user_id) INTO v_user_exists;
  
  IF NOT v_user_exists THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Utilisateur non trouvé.'
    );
  END IF;

  -- Récupérer l'email de l'utilisateur
  SELECT email INTO v_user_email FROM auth.users WHERE id = p_user_id;

  -- Désactiver les abonnements actifs existants du même type
  UPDATE driver_subscriptions
  SET status = 'expired', updated_at = NOW()
  WHERE user_id = p_user_id
    AND subscription_type = p_type
    AND status = 'active';

  -- Calculer les dates
  v_start_date := NOW();
  v_end_date := NOW() + (p_days || ' days')::INTERVAL;

  -- Créer le nouvel abonnement
  INSERT INTO driver_subscriptions (
    user_id,
    subscription_type,
    status,
    start_date,
    end_date,
    price,
    payment_method,
    created_at,
    updated_at
  ) VALUES (
    p_user_id,
    p_type,
    'active',
    v_start_date,
    v_end_date,
    0,
    'pdg_gift',
    NOW(),
    NOW()
  )
  RETURNING id INTO v_subscription_id;

  RETURN json_build_object(
    'success', true,
    'subscription_id', v_subscription_id,
    'user_email', v_user_email,
    'type', p_type,
    'days', p_days,
    'start_date', v_start_date,
    'end_date', v_end_date
  );
END;
$$;

-- Donner les droits d'exécution aux utilisateurs authentifiés
GRANT EXECUTE ON FUNCTION public.pdg_offer_subscription(UUID, TEXT, INTEGER) TO authenticated;

-- Ajouter 'pdg_gift' comme méthode de paiement valide si pas déjà présent
DO $$
BEGIN
  -- Supprimer l'ancienne contrainte si elle existe
  ALTER TABLE driver_subscriptions DROP CONSTRAINT IF EXISTS driver_subscriptions_payment_method_check;
  
  -- Ajouter la nouvelle contrainte avec pdg_gift
  ALTER TABLE driver_subscriptions ADD CONSTRAINT driver_subscriptions_payment_method_check 
    CHECK (payment_method IN ('orange_money', 'mtn_money', 'card', 'cash', 'wallet', 'pdg_gift'));
EXCEPTION
  WHEN others THEN
    -- Ignorer les erreurs si la contrainte n'existe pas ou autre
    NULL;
END $$;