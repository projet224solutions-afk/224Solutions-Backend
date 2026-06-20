-- ================================================================
-- FIX record_service_subscription_payment — filtre user_id manquant
-- (2026-05-17)
--
-- Problème :
--   Le UPDATE qui annule l'ancien abonnement actif n'avait pas de
--   filtre user_id → il annulait les abonnements de TOUS les
--   utilisateurs sur ce service, pas seulement celui qui souscrit.
--
-- Fix :
--   Ajouter AND user_id = p_user_id dans le WHERE de cet UPDATE.
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
BEGIN
  -- Calculer la date de fin selon le cycle
  v_end_date := CASE p_billing_cycle
    WHEN 'yearly'   THEN now() + INTERVAL '1 year'
    WHEN 'lifetime' THEN now() + INTERVAL '100 years'
    ELSE                 now() + INTERVAL '1 month'
  END;

  -- Paiement par wallet : vérifier et débiter
  IF p_payment_method = 'wallet' AND p_price_paid > 0 THEN

    -- Les plans de services sont toujours facturés en GNF (monthly_price_gnf)
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

    -- Enregistrer la transaction wallet (colonnes correctes)
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
        'service_id',   p_service_id,
        'plan_id',      p_plan_id,
        'billing_cycle', p_billing_cycle
      )
    );
  END IF;

  -- Annuler l'ancien abonnement actif DE CET UTILISATEUR pour ce service
  -- (filtre user_id ajouté pour ne pas toucher les abonnements d'autres utilisateurs)
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

  -- Enregistrer les revenus PDG si la fonction existe
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

SELECT 'record_service_subscription_payment — fix user_id filter dans annulation anciens abonnements.' AS status;
