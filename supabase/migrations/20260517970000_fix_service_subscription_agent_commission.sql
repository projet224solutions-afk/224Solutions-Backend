-- ================================================================
-- FIX record_service_subscription_payment — commission agent manquante
-- (2026-05-17)
--
-- Problème :
--   record_service_subscription_payment ne appelait pas
--   credit_agent_commission → l'agent qui a créé/recruté le
--   prestataire ne recevait aucune commission sur ses abonnements
--   de service de proximité.
--
--   À comparer avec record_subscription_payment (abonnements
--   marketplace) qui appelle bien credit_agent_commission.
--
-- Fix :
--   Après le paiement wallet, appeler credit_agent_commission avec
--   p_user_id du prestataire et source_type = 'service_subscription'.
--   La fonction get_user_agent cherche dans agent_created_users ET
--   user_agent_affiliations — elle gère automatiquement le cas où
--   l'utilisateur n'a pas d'agent (retourne has_agent = false).
-- ================================================================

CREATE OR REPLACE FUNCTION public.record_service_subscription_payment(
  p_user_id            UUID,
  p_service_id         UUID,
  p_plan_id            UUID,
  p_price_paid         NUMERIC,
  p_payment_method     TEXT    DEFAULT 'wallet',
  p_payment_transaction_id TEXT DEFAULT NULL,
  p_billing_cycle      TEXT    DEFAULT 'monthly'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subscription_id  UUID;
  v_end_date         TIMESTAMPTZ;
  v_wallet_balance   NUMERIC;
  v_wallet_currency  TEXT    := 'GNF';
  v_transaction_id   TEXT;
  v_commission_uuid  UUID;
BEGIN
  -- Calculer la date de fin selon le cycle
  v_end_date := CASE p_billing_cycle
    WHEN 'yearly'   THEN now() + INTERVAL '1 year'
    WHEN 'lifetime' THEN now() + INTERVAL '100 years'
    ELSE                 now() + INTERVAL '1 month'
  END;

  -- Paiement par wallet : vérifier et débiter
  IF p_payment_method = 'wallet' AND p_price_paid > 0 THEN

    v_wallet_currency := 'GNF';

    -- Vérifier le solde (avec filtre devise + verrou)
    SELECT balance INTO v_wallet_balance
    FROM public.wallets
    WHERE user_id = p_user_id
      AND currency = v_wallet_currency
    FOR UPDATE;

    IF v_wallet_balance IS NULL THEN
      RAISE EXCEPTION 'Portefeuille introuvable en % pour cet utilisateur', v_wallet_currency;
    END IF;

    IF v_wallet_balance < p_price_paid THEN
      RAISE EXCEPTION 'Solde % insuffisant (disponible : %, requis : %)',
        v_wallet_currency, v_wallet_balance, p_price_paid;
    END IF;

    -- Déduire du wallet
    UPDATE public.wallets
    SET    balance    = balance - p_price_paid,
           updated_at = now()
    WHERE  user_id  = p_user_id
      AND  currency = v_wallet_currency;

    -- Enregistrer la transaction wallet
    v_transaction_id := 'sub-' || left(replace(gen_random_uuid()::text, '-', ''), 45);

    INSERT INTO public.wallet_transactions (
      transaction_id,
      sender_user_id,
      transaction_type,
      amount,
      fee,
      net_amount,
      currency,
      description,
      status,
      metadata
    ) VALUES (
      v_transaction_id,
      p_user_id,
      'payment'::transaction_type,
      p_price_paid,
      0,
      p_price_paid,
      v_wallet_currency,
      'Abonnement service professionnel',
      'completed'::transaction_status,
      jsonb_build_object(
        'service_id',    p_service_id,
        'plan_id',       p_plan_id,
        'billing_cycle', p_billing_cycle
      )
    );

    -- Créditer la commission à l'agent du prestataire (si applicable)
    -- UUID dédié pour l'anti-doublon dans credit_agent_commission
    v_commission_uuid := gen_random_uuid();
    BEGIN
      PERFORM credit_agent_commission(
        p_user_id,
        p_price_paid,
        'service_subscription',
        v_commission_uuid,
        jsonb_build_object(
          'service_id',    p_service_id,
          'plan_id',       p_plan_id,
          'billing_cycle', p_billing_cycle,
          'currency',      v_wallet_currency
        )
      );
    EXCEPTION WHEN OTHERS THEN
      -- Ne pas bloquer l'abonnement si la commission échoue
      RAISE WARNING 'credit_agent_commission failed for user %: %', p_user_id, SQLERRM;
    END;

  END IF;

  -- Annuler l'ancien abonnement actif DE CET UTILISATEUR pour ce service
  UPDATE public.service_subscriptions
  SET    status       = 'cancelled',
         cancelled_at = now(),
         updated_at   = now()
  WHERE  professional_service_id = p_service_id
    AND  user_id = p_user_id
    AND  status  = 'active';

  -- Créer le nouvel abonnement
  INSERT INTO public.service_subscriptions (
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
    p_price_paid::INTEGER,
    p_payment_method,
    COALESCE(p_payment_transaction_id, v_transaction_id),
    now(),
    now(),
    v_end_date,
    p_billing_cycle != 'lifetime'
  )
  RETURNING id INTO v_subscription_id;

  -- Enregistrer le paiement dans service_subscription_payments
  INSERT INTO public.service_subscription_payments (
    subscription_id,
    user_id,
    amount_gnf,
    payment_method,
    transaction_reference,
    status
  ) VALUES (
    v_subscription_id,
    p_user_id,
    p_price_paid::INTEGER,
    p_payment_method,
    COALESCE(p_payment_transaction_id, v_transaction_id),
    'completed'
  );

  -- Enregistrer les revenus PDG
  BEGIN
    PERFORM record_pdg_revenue(
      p_price_paid,
      'service_subscription',
      'Abonnement service professionnel',
      jsonb_build_object(
        'service_id',      p_service_id,
        'plan_id',         p_plan_id,
        'subscription_id', v_subscription_id
      )
    );
  EXCEPTION WHEN undefined_function THEN
    NULL;
  END;

  RETURN v_subscription_id;
END;
$$;

SELECT 'record_service_subscription_payment — commission agent ajoutée (service_subscription).' AS status;
