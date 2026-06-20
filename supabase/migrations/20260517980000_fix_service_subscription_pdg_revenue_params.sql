-- ================================================================
-- FIX record_service_subscription_payment — paramètres record_pdg_revenue
-- (2026-05-17)
--
-- Problème :
--   Les 3 migrations précédentes (950000, 960000, 970000) appelaient
--   record_pdg_revenue avec les paramètres dans le MAUVAIS ORDRE :
--
--     record_pdg_revenue(p_price_paid, 'service_subscription', 'Abonnement...', jsonb_build_object(...))
--     → PostgreSQL reçoit  (numeric, text, text, jsonb)
--     → Signature réelle : (text, numeric, numeric, uuid, uuid, uuid, jsonb)
--
--   PostgreSQL ne peut pas convertir text→numeric implicitement → erreur
--   42883 (function does not exist) → avalée silencieusement par le bloc
--   EXCEPTION WHEN undefined_function → aucun revenu PDG enregistré.
--
-- Fix :
--   Passer les paramètres dans le bon ordre :
--     (p_source_type TEXT, p_amount NUMERIC, p_percentage NUMERIC,
--      p_transaction_id UUID, p_user_id UUID, p_service_id UUID, p_metadata JSONB)
--
-- Autres points vérifiés et corrects :
--   - credit_agent_commission reçoit bien un UUID via gen_random_uuid()
--   - agent_commissions_log.transaction_id est UUID ✅
--   - get_user_agent cherche par user_id dans agent_created_users et
--     user_agent_affiliations ✅
--   - Pas de commission sur les abonnements gratuits (price = 0) ✅
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
    -- get_user_agent cherche dans agent_created_users ET user_agent_affiliations
    -- Si l'utilisateur n'a pas d'agent, retourne has_agent=false sans erreur
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

  -- Enregistrer les revenus PDG — paramètres dans le BON ORDRE :
  -- (p_source_type TEXT, p_amount NUMERIC, p_percentage NUMERIC,
  --  p_transaction_id UUID, p_user_id UUID, p_service_id UUID, p_metadata JSONB)
  BEGIN
    PERFORM record_pdg_revenue(
      'service_subscription',
      p_price_paid,
      100,
      NULL,
      p_user_id,
      p_service_id,
      jsonb_build_object(
        'service_id',      p_service_id,
        'plan_id',         p_plan_id,
        'subscription_id', v_subscription_id,
        'billing_cycle',   p_billing_cycle
      )
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'record_pdg_revenue failed for service %: %', p_service_id, SQLERRM;
  END;

  RETURN v_subscription_id;
END;
$$;

SELECT 'record_service_subscription_payment — fix record_pdg_revenue paramètres + commission agent.' AS status;
