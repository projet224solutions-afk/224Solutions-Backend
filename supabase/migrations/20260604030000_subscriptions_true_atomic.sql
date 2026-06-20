-- =====================================================================
-- ABONNEMENTS — VRAIE ATOMICITÉ (débit wallet + écriture abonnement = 1 transaction)
-- =====================================================================
-- AVANT : les 3 flux d'abonnement (vendeur, service de proximité, livreur/taxi)
-- faisaient debitWallet() PUIS insert/update de l'abonnement en 2 étapes Node
-- séparées, avec remboursement de compensation si la 2e échouait (pattern saga).
-- → fenêtre résiduelle : crash entre le débit et le remboursement = argent
--   débité sans abonnement.
--
-- MAINTENANT : un helper SQL `wallet_debit_internal` (verrou FOR UPDATE, contrôle
-- solde/blocage, journal wallet_transactions, idempotence) + 3 RPC qui DÉBITENT
-- et ÉCRIVENT l'abonnement dans la MÊME transaction. En cas d'erreur, tout est
-- annulé (ROLLBACK) → impossible d'avoir un débit sans abonnement.
--
-- Le calcul du prix / proration / commission d'affiliation reste côté Node ;
-- seul le couple sensible (débit ↔ écriture) devient transactionnel.
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

-- ─────────────────────────────────────────────────────────────────────
-- HELPER : débit wallet DANS la transaction de l'appelant.
-- Lève une exception (rollback) si wallet absent/bloqué/solde insuffisant.
-- Reproduit fidèlement debitWallet() : wallet_transactions (withdrawal,
-- net_amount, receiver null pour respecter le CHECK different_wallets) + clé
-- d'idempotence best-effort. Retourne le nouveau solde (NULL si montant<=0).
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.wallet_debit_internal(
  p_user_id uuid,
  p_amount numeric,
  p_description text,
  p_idempotency_key text
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id uuid;
  v_balance numeric;
  v_blocked boolean;
  v_currency text;
BEGIN
  IF p_amount IS NULL OR p_amount = 0 THEN
    RETURN NULL; -- plan gratuit : aucun débit
  END IF;
  IF p_amount < 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT'; -- montant négatif = anomalie → rollback
  END IF;

  SELECT id, balance, COALESCE(is_blocked, false), COALESCE(currency, 'GNF')
  INTO   v_wallet_id, v_balance, v_blocked, v_currency
  FROM   public.wallets
  WHERE  user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'WALLET_NOT_FOUND'; END IF;
  IF v_blocked THEN RAISE EXCEPTION 'WALLET_BLOCKED'; END IF;

  -- Idempotence anti double-débit : le verrou FOR UPDATE ci-dessus sérialise les
  -- appels concurrents pour CE wallet → le 2e voit la clé et est rejeté (rollback).
  IF p_idempotency_key IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.wallet_idempotency_keys WHERE idempotency_key = p_idempotency_key) THEN
    RAISE EXCEPTION 'DUPLICATE_PAYMENT';
  END IF;

  IF v_balance < p_amount THEN RAISE EXCEPTION 'INSUFFICIENT_FUNDS'; END IF;

  UPDATE public.wallets
  SET balance = v_balance - p_amount, updated_at = now()
  WHERE id = v_wallet_id;

  INSERT INTO public.wallet_transactions (
    transaction_id, sender_wallet_id, receiver_wallet_id, sender_user_id, receiver_user_id,
    transaction_type, amount, net_amount, status, currency, description, metadata
  ) VALUES (
    gen_random_uuid(), v_wallet_id, NULL, p_user_id, NULL,
    'withdrawal', p_amount, p_amount, 'completed', v_currency, p_description,
    jsonb_build_object('idempotency_key', p_idempotency_key, 'source', 'backend-rpc-atomic')
  );

  -- Idempotence best-effort (ne doit jamais faire échouer la transaction)
  BEGIN
    INSERT INTO public.wallet_idempotency_keys (idempotency_key, user_id, operation, created_at, expires_at)
    VALUES (p_idempotency_key, p_user_id, 'withdraw', now(), now() + interval '24 hours');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_balance - p_amount;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────
-- RPC 1 : Abonnement VENDEUR (table subscriptions) — modes 'new' et 'switch'
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.purchase_vendor_subscription_atomic(
  p_user_id uuid,
  p_amount numeric,
  p_idempotency_key text,
  p_description text,
  p_mode text,                 -- 'new' | 'switch'
  p_plan_id uuid,
  p_cycle text,
  p_payment_method text,
  p_period_start timestamptz,
  p_period_end timestamptz,
  p_auto_renew boolean,
  p_metadata jsonb,
  p_current_sub_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_balance numeric;
  v_sub_id uuid;
BEGIN
  v_new_balance := public.wallet_debit_internal(p_user_id, p_amount, p_description, p_idempotency_key);

  IF p_mode = 'switch' THEN
    UPDATE public.subscriptions
    SET plan_id = p_plan_id, updated_at = now(), metadata = p_metadata
    WHERE id = p_current_sub_id
    RETURNING id INTO v_sub_id;
    IF v_sub_id IS NULL THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_FOUND'; END IF;
  ELSE
    -- Expirer AVANT d'insérer (compatible avec l'index unique partiel
    -- « un seul abonnement payant actif » → pas de violation d'unicité au renouvellement)
    UPDATE public.subscriptions
    SET status = 'expired', updated_at = now()
    WHERE user_id = p_user_id AND status IN ('active', 'trialing');

    INSERT INTO public.subscriptions (
      user_id, plan_id, price_paid_gnf, billing_cycle, status,
      started_at, current_period_start, current_period_end, auto_renew, payment_method, metadata
    ) VALUES (
      p_user_id, p_plan_id, COALESCE(p_amount, 0), p_cycle, 'active',
      p_period_start, p_period_start, p_period_end, p_auto_renew, p_payment_method, p_metadata
    )
    RETURNING id INTO v_sub_id;
  END IF;

  RETURN jsonb_build_object('status', 'created', 'subscription_id', v_sub_id, 'new_balance', v_new_balance, 'mode', p_mode);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;

-- ─────────────────────────────────────────────────────────────────────
-- RPC 2 : Abonnement SERVICE de proximité (table service_subscriptions)
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.purchase_service_subscription_atomic(
  p_user_id uuid,
  p_amount numeric,
  p_idempotency_key text,
  p_description text,
  p_mode text,                 -- 'new' | 'switch'
  p_service_id uuid,
  p_plan_id uuid,
  p_cycle text,
  p_payment_method text,
  p_period_start timestamptz,
  p_period_end timestamptz,
  p_auto_renew boolean,
  p_metadata jsonb,
  p_current_sub_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_balance numeric;
  v_sub_id uuid;
BEGIN
  v_new_balance := public.wallet_debit_internal(p_user_id, p_amount, p_description, p_idempotency_key);

  IF p_mode = 'switch' THEN
    UPDATE public.service_subscriptions
    SET plan_id = p_plan_id, updated_at = now(), metadata = p_metadata
    WHERE id = p_current_sub_id
    RETURNING id INTO v_sub_id;
    IF v_sub_id IS NULL THEN RAISE EXCEPTION 'SUBSCRIPTION_NOT_FOUND'; END IF;
  ELSE
    -- Expirer AVANT d'insérer (compatible index unique partiel par service)
    UPDATE public.service_subscriptions
    SET status = 'expired', updated_at = now()
    WHERE professional_service_id = p_service_id AND user_id = p_user_id
      AND status IN ('active', 'trialing');

    INSERT INTO public.service_subscriptions (
      professional_service_id, user_id, plan_id, price_paid_gnf, billing_cycle, status,
      started_at, current_period_start, current_period_end, auto_renew, payment_method, metadata
    ) VALUES (
      p_service_id, p_user_id, p_plan_id, COALESCE(p_amount, 0), p_cycle, 'active',
      p_period_start, p_period_start, p_period_end, p_auto_renew, p_payment_method, p_metadata
    )
    RETURNING id INTO v_sub_id;
  END IF;

  RETURN jsonb_build_object('status', 'created', 'subscription_id', v_sub_id, 'new_balance', v_new_balance, 'mode', p_mode);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;

-- ─────────────────────────────────────────────────────────────────────
-- RPC 3 : Abonnement LIVREUR / TAXI (table driver_subscriptions) — 'new' uniquement
-- + revenu best-effort (driver_subscription_revenues)
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.purchase_driver_subscription_atomic(
  p_user_id uuid,
  p_amount numeric,
  p_idempotency_key text,
  p_description text,
  p_driver_type text,          -- 'livreur' | 'taxi'
  p_cycle text,
  p_payment_method text,
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_transaction_id text,
  p_metadata jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_balance numeric;
  v_sub_id uuid;
BEGIN
  v_new_balance := public.wallet_debit_internal(p_user_id, p_amount, p_description, p_idempotency_key);

  -- Expirer les anciens abonnements actifs (un seul actif)
  UPDATE public.driver_subscriptions
  SET status = 'expired', updated_at = now()
  WHERE user_id = p_user_id AND status = 'active';

  INSERT INTO public.driver_subscriptions (
    user_id, type, price, status, start_date, end_date, payment_method, transaction_id, billing_cycle, metadata
  ) VALUES (
    p_user_id, p_driver_type, COALESCE(p_amount, 0), 'active', p_start_date, p_end_date,
    p_payment_method, p_transaction_id, p_cycle, p_metadata
  )
  RETURNING id INTO v_sub_id;

  -- Revenu best-effort (ne fait pas échouer la transaction)
  BEGIN
    INSERT INTO public.driver_subscription_revenues (subscription_id, user_id, amount, payment_method, transaction_id)
    VALUES (v_sub_id, p_user_id, COALESCE(p_amount, 0), p_payment_method, p_transaction_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('status', 'created', 'subscription_id', v_sub_id, 'new_balance', v_new_balance, 'mode', 'new');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;
