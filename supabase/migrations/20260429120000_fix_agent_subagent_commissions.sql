-- End-to-end fix for agent/sub-agent commissions and permissions.
-- Main rules:
-- - A direct PDG agent receives its configured rate, default 20%.
-- - A sub-agent receives its own rate, and its parent receives the parent rate.
-- - Agent wallet credits must target the GNF wallet only.
-- - Paid subscriptions also trigger agent commissions.

CREATE OR REPLACE FUNCTION public.credit_agent_wallet_gnf(
  p_agent_id uuid,
  p_amount numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF p_agent_id IS NULL OR COALESCE(p_amount, 0) <= 0 THEN
    RETURN;
  END IF;

  INSERT INTO public.agent_wallets (
    agent_id,
    balance,
    currency,
    wallet_status,
    currency_type,
    updated_at
  ) VALUES (
    p_agent_id,
    ROUND(p_amount, 2),
    'GNF',
    'active',
    'GNF',
    NOW()
  )
  ON CONFLICT (agent_id, currency_type)
  DO UPDATE SET
    balance = COALESCE(public.agent_wallets.balance, 0) + EXCLUDED.balance,
    currency = 'GNF',
    wallet_status = COALESCE(public.agent_wallets.wallet_status, 'active'),
    updated_at = NOW();
END;
$$;

REVOKE ALL ON FUNCTION public.credit_agent_wallet_gnf(uuid, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_agent_wallet_gnf(uuid, numeric) TO service_role;

CREATE OR REPLACE FUNCTION public.credit_agent_commission(
  p_user_id uuid,
  p_amount numeric,
  p_source_type text,
  p_transaction_id uuid DEFAULT NULL::uuid,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_affiliation RECORD;
  v_agent RECORD;
  v_parent_agent RECORD;
  v_commission_rate numeric;
  v_sub_agent_rate numeric;
  v_agent_commission numeric := 0;
  v_parent_commission numeric := 0;
  v_agent_log_id uuid;
  v_parent_log_id uuid;
  v_any_inserted boolean := false;
  v_agent_duplicate boolean := false;
  v_parent_duplicate boolean := false;
  v_currency text := COALESCE(NULLIF(p_metadata->>'currency', ''), 'GNF');
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Utilisateur requis');
  END IF;

  IF COALESCE(p_amount, 0) <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Montant invalide');
  END IF;

  SELECT * INTO v_affiliation
  FROM public.get_user_agent(p_user_id);

  IF v_affiliation.agent_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'has_agent', false,
      'message', 'Utilisateur non affilie a un agent'
    );
  END IF;

  SELECT * INTO v_agent
  FROM public.agents_management
  WHERE id = v_affiliation.agent_id
    AND is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent non trouve ou inactif');
  END IF;

  IF v_agent.type_agent = 'sous_agent' THEN
    v_sub_agent_rate := GREATEST(0, LEAST(COALESCE(v_agent.commission_sous_agent, v_agent.commission_rate, 10), 100));
    v_agent_commission := ROUND(p_amount * (v_sub_agent_rate / 100), 2);

    IF v_agent_commission > 0 THEN
      INSERT INTO public.agent_commissions_log (
        agent_id,
        amount,
        source_type,
        related_user_id,
        transaction_id,
        description,
        status,
        commission_rate,
        transaction_amount,
        currency
      ) VALUES (
        v_agent.id,
        v_agent_commission,
        p_source_type,
        p_user_id,
        p_transaction_id,
        'Commission sous-agent ' || v_sub_agent_rate || '% sur ' || p_source_type,
        'validated',
        v_sub_agent_rate,
        ROUND(p_amount, 2),
        v_currency
      )
      ON CONFLICT DO NOTHING
      RETURNING id INTO v_agent_log_id;

      IF v_agent_log_id IS NULL THEN
        v_agent_duplicate := true;
        v_agent_commission := 0;
      ELSE
        PERFORM public.credit_agent_wallet_gnf(v_agent.id, v_agent_commission);
        v_any_inserted := true;
      END IF;
    END IF;

    IF v_agent.parent_agent_id IS NOT NULL THEN
      SELECT * INTO v_parent_agent
      FROM public.agents_management
      WHERE id = v_agent.parent_agent_id
        AND is_active = true;

      IF FOUND THEN
        v_commission_rate := GREATEST(0, LEAST(COALESCE(v_parent_agent.commission_agent_principal, v_parent_agent.commission_rate, 15), 100));
        v_parent_commission := ROUND(p_amount * (v_commission_rate / 100), 2);

        IF v_parent_commission > 0 THEN
          INSERT INTO public.agent_commissions_log (
            agent_id,
            amount,
            source_type,
            related_user_id,
            transaction_id,
            description,
            status,
            commission_rate,
            transaction_amount,
            currency
          ) VALUES (
            v_parent_agent.id,
            v_parent_commission,
            p_source_type,
            p_user_id,
            p_transaction_id,
            'Commission agent principal ' || v_commission_rate || '% via sous-agent ' || v_agent.name,
            'validated',
            v_commission_rate,
            ROUND(p_amount, 2),
            v_currency
          )
          ON CONFLICT DO NOTHING
          RETURNING id INTO v_parent_log_id;

          IF v_parent_log_id IS NULL THEN
            v_parent_duplicate := true;
            v_parent_commission := 0;
          ELSE
            PERFORM public.credit_agent_wallet_gnf(v_parent_agent.id, v_parent_commission);
            v_any_inserted := true;
          END IF;
        END IF;
      END IF;
    END IF;

    RETURN jsonb_build_object(
      'success', true,
      'has_agent', true,
      'already_processed', (NOT v_any_inserted AND (v_agent_duplicate OR v_parent_duplicate)),
      'agent_type', 'sous_agent',
      'agent_id', v_agent.id,
      'agent_name', v_agent.name,
      'agent_commission', v_agent_commission,
      'agent_rate', v_sub_agent_rate,
      'parent_agent_id', v_agent.parent_agent_id,
      'parent_commission', COALESCE(v_parent_commission, 0),
      'parent_already_processed', v_parent_duplicate,
      'total_commissions', v_agent_commission + COALESCE(v_parent_commission, 0)
    );
  END IF;

  v_commission_rate := GREATEST(0, LEAST(COALESCE(v_agent.commission_rate, v_agent.commission_agent_principal, 20), 100));
  v_agent_commission := ROUND(p_amount * (v_commission_rate / 100), 2);

  IF v_agent_commission > 0 THEN
    INSERT INTO public.agent_commissions_log (
      agent_id,
      amount,
      source_type,
      related_user_id,
      transaction_id,
      description,
      status,
      commission_rate,
      transaction_amount,
      currency
    ) VALUES (
      v_agent.id,
      v_agent_commission,
      p_source_type,
      p_user_id,
      p_transaction_id,
      'Commission agent principal ' || v_commission_rate || '% sur ' || p_source_type,
      'validated',
      v_commission_rate,
      ROUND(p_amount, 2),
      v_currency
    )
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_agent_log_id;

    IF v_agent_log_id IS NULL THEN
      v_agent_duplicate := true;
      v_agent_commission := 0;
    ELSE
      PERFORM public.credit_agent_wallet_gnf(v_agent.id, v_agent_commission);
      v_any_inserted := true;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'has_agent', true,
    'already_processed', (NOT v_any_inserted AND v_agent_duplicate),
    'agent_type', COALESCE(v_agent.type_agent, 'principal'),
    'agent_id', v_agent.id,
    'agent_name', v_agent.name,
    'agent_commission', v_agent_commission,
    'agent_rate', v_commission_rate,
    'total_commissions', v_agent_commission
  );
END;
$$;

REVOKE ALL ON FUNCTION public.credit_agent_commission(uuid, numeric, text, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_agent_commission(uuid, numeric, text, uuid, jsonb) TO service_role;

DROP VIEW IF EXISTS public.agent_commission_stats;
CREATE VIEW public.agent_commission_stats AS
WITH gnf_wallets AS (
  SELECT
    aw.agent_id,
    COALESCE(SUM(aw.balance), 0::numeric) AS balance
  FROM public.agent_wallets aw
  WHERE COALESCE(aw.currency_type, aw.currency, 'GNF') = 'GNF'
  GROUP BY aw.agent_id
)
SELECT
  a.id AS agent_id,
  a.name AS agent_name,
  a.agent_code,
  COALESCE(w.balance, 0::numeric) AS wallet_balance,
  (SELECT count(*) FROM public.agent_created_users acu WHERE acu.agent_id = a.id) AS direct_users,
  (SELECT count(*) FROM public.user_agent_affiliations uaa WHERE uaa.agent_id = a.id AND uaa.is_verified = true) AS affiliated_users,
  (SELECT COALESCE(sum(cl.amount), 0::numeric) FROM public.agent_commissions_log cl WHERE cl.agent_id = a.id) AS total_commissions_earned,
  (SELECT COALESCE(sum(cl.amount), 0::numeric) FROM public.agent_commissions_log cl WHERE cl.agent_id = a.id AND cl.created_at >= date_trunc('month', now())) AS commissions_this_month,
  (SELECT COALESCE(sum(cl.amount), 0::numeric) FROM public.agent_commissions_log cl WHERE cl.agent_id = a.id AND cl.status = 'pending') AS pending_commissions
FROM public.agents_management a
LEFT JOIN gnf_wallets w ON w.agent_id = a.id;

CREATE OR REPLACE FUNCTION public.subscribe_user(
  p_user_id uuid,
  p_plan_id uuid,
  p_payment_method text DEFAULT 'wallet',
  p_transaction_id text DEFAULT NULL,
  p_billing_cycle text DEFAULT 'monthly'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_subscription_id uuid;
  v_price integer;
  v_duration_days integer;
  v_period_end timestamptz;
  v_plan_name text;
  v_user_role text;
  v_wallet_id uuid;
  v_wallet_balance integer;
  v_wallet_transaction_id uuid;
  v_commission_result jsonb := '{}'::jsonb;
BEGIN
  SELECT
    CASE
      WHEN p_billing_cycle = 'yearly' THEN COALESCE(yearly_price_gnf, monthly_price_gnf * 12)
      WHEN p_billing_cycle = 'quarterly' THEN monthly_price_gnf * 3
      ELSE monthly_price_gnf
    END,
    CASE
      WHEN p_billing_cycle = 'yearly' THEN COALESCE(duration_days, 30) * 12
      WHEN p_billing_cycle = 'quarterly' THEN COALESCE(duration_days, 30) * 3
      ELSE COALESCE(duration_days, 30)
    END,
    name,
    COALESCE(user_role, 'vendeur')
  INTO v_price, v_duration_days, v_plan_name, v_user_role
  FROM public.plans
  WHERE id = p_plan_id
    AND is_active = true;

  IF v_price IS NULL THEN
    RAISE EXCEPTION 'Plan non trouve ou inactif (ID: %)', p_plan_id;
  END IF;

  IF p_payment_method = 'wallet' THEN
    SELECT id, COALESCE(balance, 0)::integer
    INTO v_wallet_id, v_wallet_balance
    FROM public.wallets
    WHERE user_id = p_user_id
      AND currency = 'GNF'
    LIMIT 1
    FOR UPDATE;

    IF v_wallet_id IS NULL THEN
      INSERT INTO public.wallets (user_id, balance, currency)
      VALUES (p_user_id, 0, 'GNF')
      RETURNING id, 0 INTO v_wallet_id, v_wallet_balance;
    END IF;

    IF v_wallet_balance < v_price THEN
      RAISE EXCEPTION 'Solde insuffisant: % GNF disponible, % GNF requis pour l''abonnement %',
        v_wallet_balance, v_price, v_plan_name;
    END IF;

    UPDATE public.wallets
    SET balance = balance - v_price,
        updated_at = NOW()
    WHERE id = v_wallet_id;

    INSERT INTO public.wallet_transactions (
      wallet_id,
      transaction_type,
      amount,
      balance_before,
      balance_after,
      description,
      status,
      metadata,
      created_at
    ) VALUES (
      v_wallet_id,
      'subscription',
      v_price,
      v_wallet_balance,
      v_wallet_balance - v_price,
      'Abonnement ' || v_plan_name || ' (' || p_billing_cycle || ')',
      'completed',
      jsonb_build_object(
        'plan_id', p_plan_id,
        'plan_name', v_plan_name,
        'billing_cycle', p_billing_cycle,
        'user_role', v_user_role,
        'payment_method', p_payment_method
      ),
      NOW()
    )
    RETURNING id INTO v_wallet_transaction_id;
  END IF;

  v_period_end := NOW() + (v_duration_days || ' days')::interval;

  UPDATE public.subscriptions
  SET status = 'expired',
      auto_renew = false,
      updated_at = NOW()
  WHERE user_id = p_user_id
    AND status = 'active';

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
  ) VALUES (
    p_user_id,
    p_plan_id,
    v_price,
    p_billing_cycle,
    'active',
    NOW(),
    v_period_end,
    true,
    p_payment_method,
    COALESCE(p_transaction_id, v_wallet_transaction_id::text),
    jsonb_build_object(
      'migrated', false,
      'plan_type', v_user_role,
      'wallet_transaction_id', v_wallet_transaction_id,
      'created_by', 'subscribe_user_v3'
    ),
    NOW(),
    NOW()
  )
  RETURNING id INTO v_subscription_id;

  IF v_price > 0 THEN
    v_commission_result := public.credit_agent_commission(
      p_user_id,
      v_price,
      'abonnement',
      v_subscription_id,
      jsonb_build_object(
        'currency', 'GNF',
        'subscription_id', v_subscription_id,
        'plan_id', p_plan_id,
        'plan_name', v_plan_name,
        'billing_cycle', p_billing_cycle,
        'wallet_transaction_id', v_wallet_transaction_id
      )
    );

    UPDATE public.subscriptions
    SET metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('agent_commission', v_commission_result),
        updated_at = NOW()
    WHERE id = v_subscription_id;
  END IF;

  INSERT INTO public.revenus_pdg (
    source_type,
    transaction_id,
    user_id,
    amount,
    percentage_applied,
    description,
    metadata,
    created_at
  ) VALUES (
    'frais_abonnement',
    v_subscription_id,
    p_user_id,
    v_price,
    100,
    'Abonnement ' || v_plan_name || ' (' || p_billing_cycle || ')',
    jsonb_build_object(
      'subscription_id', v_subscription_id,
      'plan_id', p_plan_id,
      'plan_name', v_plan_name,
      'billing_cycle', p_billing_cycle,
      'user_role', v_user_role,
      'wallet_transaction_id', v_wallet_transaction_id,
      'agent_commission', v_commission_result
    ),
    NOW()
  );

  RETURN v_subscription_id;
END;
$$;

DROP FUNCTION IF EXISTS public.record_subscription_payment(uuid, uuid, integer, text, text, text);
DROP FUNCTION IF EXISTS public.record_subscription_payment(uuid, uuid, numeric, text, text, text);
DROP FUNCTION IF EXISTS public.record_subscription_payment(uuid, uuid, integer, varchar, uuid, varchar);
DROP FUNCTION IF EXISTS public.record_subscription_payment(uuid, uuid, numeric, text, uuid, text);

CREATE OR REPLACE FUNCTION public.record_subscription_payment(
  p_user_id uuid,
  p_plan_id uuid,
  p_price_paid numeric,
  p_payment_method text DEFAULT 'wallet',
  p_payment_transaction_id text DEFAULT NULL,
  p_billing_cycle text DEFAULT 'monthly'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  RETURN public.subscribe_user(
    p_user_id,
    p_plan_id,
    p_payment_method,
    p_payment_transaction_id,
    p_billing_cycle
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.subscribe_user(uuid, uuid, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_subscription_payment(uuid, uuid, numeric, text, text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.process_successful_payment(p_transaction_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transaction RECORD;
  v_seller_wallet_id uuid;
  v_platform_wallet_id uuid;
  v_platform_user_id uuid;
  v_platform_balance_before numeric;
  v_platform_balance_after numeric;
  v_seller_balance_before numeric;
  v_seller_balance_after numeric;
  v_commission_result jsonb;
  v_commission_transaction_id uuid;
BEGIN
  SELECT * INTO v_transaction
  FROM public.stripe_transactions
  WHERE id = p_transaction_id;

  IF v_transaction.id IS NULL THEN
    RAISE EXCEPTION 'Transaction not found';
  END IF;

  v_seller_wallet_id := public.get_or_create_wallet(v_transaction.seller_id);

  SELECT id INTO v_platform_user_id
  FROM public.profiles
  WHERE role = 'CEO'
  LIMIT 1;

  IF v_platform_user_id IS NOT NULL THEN
    v_platform_wallet_id := public.get_or_create_wallet(v_platform_user_id);
  END IF;

  SELECT balance INTO v_seller_balance_before
  FROM public.wallets
  WHERE id = v_seller_wallet_id;

  UPDATE public.wallets
  SET balance = balance + v_transaction.seller_net_amount,
      updated_at = NOW()
  WHERE id = v_seller_wallet_id;

  SELECT balance INTO v_seller_balance_after
  FROM public.wallets
  WHERE id = v_seller_wallet_id;

  INSERT INTO public.wallet_transactions (
    sender_wallet_id,
    receiver_wallet_id,
    amount,
    currency,
    description,
    transaction_type,
    status,
    metadata,
    created_at
  ) VALUES (
    NULL,
    v_seller_wallet_id,
    v_transaction.seller_net_amount,
    v_transaction.currency,
    'Paiement recu commande ' || COALESCE(v_transaction.order_id::text, 'N/A'),
    'payment',
    'completed',
    jsonb_build_object('stripe_transaction_id', v_transaction.id, 'balance_before', v_seller_balance_before, 'balance_after', v_seller_balance_after),
    NOW()
  );

  IF v_platform_wallet_id IS NOT NULL THEN
    SELECT balance INTO v_platform_balance_before
    FROM public.wallets
    WHERE id = v_platform_wallet_id;

    UPDATE public.wallets
    SET balance = balance + v_transaction.commission_amount,
        updated_at = NOW()
    WHERE id = v_platform_wallet_id;

    SELECT balance INTO v_platform_balance_after
    FROM public.wallets
    WHERE id = v_platform_wallet_id;

    INSERT INTO public.wallet_transactions (
      sender_wallet_id,
      receiver_wallet_id,
      amount,
      currency,
      description,
      transaction_type,
      status,
      metadata,
      created_at
    ) VALUES (
      NULL,
      v_platform_wallet_id,
      v_transaction.commission_amount,
      v_transaction.currency,
      'Commission plateforme commande ' || COALESCE(v_transaction.order_id::text, 'N/A'),
      'commission',
      'completed',
      jsonb_build_object('stripe_transaction_id', v_transaction.id, 'balance_before', v_platform_balance_before, 'balance_after', v_platform_balance_after),
      NOW()
    );
  END IF;

  v_commission_transaction_id := v_transaction.id;
  IF v_transaction.order_id IS NOT NULL
     AND v_transaction.order_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    v_commission_transaction_id := v_transaction.order_id::uuid;
  END IF;

  v_commission_result := public.credit_agent_commission(
    v_transaction.buyer_id,
    v_transaction.amount,
    'achat_produit',
    v_commission_transaction_id,
    jsonb_build_object(
      'currency', COALESCE(v_transaction.currency, 'GNF'),
      'order_id', v_transaction.order_id,
      'seller_id', v_transaction.seller_id,
      'stripe_transaction_id', v_transaction.id
    )
  );

  RAISE NOTICE 'Commission agent pour achat: %', v_commission_result;
  RETURN true;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'Erreur lors du traitement du paiement: %', SQLERRM;
    RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION public.process_wallet_order_payment(
  p_user_id uuid,
  p_order_id uuid,
  p_amount numeric,
  p_vendor_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user_wallet_id uuid;
  v_user_balance numeric;
  v_vendor_wallet_id uuid;
  v_transaction_id uuid;
  v_platform_fee numeric;
  v_vendor_net numeric;
  v_commission_result jsonb;
  v_fee_rate numeric;
  v_vendor_user_id uuid;
BEGIN
  SELECT id, balance INTO v_user_wallet_id, v_user_balance
  FROM public.wallets
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_user_wallet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet utilisateur non trouve');
  END IF;

  IF v_user_balance < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solde insuffisant');
  END IF;

  SELECT user_id INTO v_vendor_user_id
  FROM public.vendors
  WHERE id = p_vendor_id;

  IF v_vendor_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendeur non trouve');
  END IF;

  SELECT id INTO v_vendor_wallet_id
  FROM public.wallets
  WHERE user_id = v_vendor_user_id;

  IF v_vendor_wallet_id IS NULL THEN
    INSERT INTO public.wallets (user_id, balance, currency)
    VALUES (v_vendor_user_id, 0, 'GNF')
    RETURNING id INTO v_vendor_wallet_id;
  END IF;

  SELECT setting_value::numeric INTO v_fee_rate
  FROM public.pdg_settings
  WHERE setting_key = 'purchase_commission_percentage';

  IF v_fee_rate IS NULL THEN
    v_fee_rate := 0.025;
  END IF;

  v_platform_fee := ROUND(p_amount * v_fee_rate, 2);
  v_vendor_net := ROUND(p_amount - v_platform_fee, 2);
  v_transaction_id := gen_random_uuid();

  UPDATE public.wallets
  SET balance = balance - ROUND(p_amount, 2),
      updated_at = NOW()
  WHERE id = v_user_wallet_id;

  UPDATE public.wallets
  SET balance = balance + v_vendor_net,
      updated_at = NOW()
  WHERE id = v_vendor_wallet_id;

  INSERT INTO public.wallet_transactions (
    id,
    sender_wallet_id,
    receiver_wallet_id,
    amount,
    fee,
    net_amount,
    currency,
    transaction_type,
    status,
    description,
    metadata,
    created_at,
    completed_at
  ) VALUES (
    v_transaction_id,
    v_user_wallet_id,
    v_vendor_wallet_id,
    ROUND(p_amount, 2),
    v_platform_fee,
    v_vendor_net,
    'GNF',
    'purchase',
    'completed',
    'Paiement commande #' || p_order_id::text,
    jsonb_build_object('order_id', p_order_id, 'vendor_id', p_vendor_id),
    NOW(),
    NOW()
  );

  v_commission_result := public.credit_agent_commission(
    p_user_id,
    ROUND(p_amount, 2),
    'achat_produit',
    p_order_id,
    jsonb_build_object(
      'currency', 'GNF',
      'order_id', p_order_id,
      'vendor_id', p_vendor_id,
      'wallet_transaction_id', v_transaction_id
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'amount', ROUND(p_amount, 2),
    'platform_fee', v_platform_fee,
    'vendor_net', v_vendor_net,
    'agent_commission', v_commission_result
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.set_agent_permissions(
  p_agent_id uuid,
  p_permissions jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_key text;
  v_value_text text;
  v_can_create_sub_agents boolean;
  v_request_role text := COALESCE(current_setting('request.jwt.claim.role', true), '');
BEGIN
  IF p_agent_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent requis');
  END IF;

  IF COALESCE(jsonb_typeof(p_permissions), 'object') <> 'object' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Format des permissions invalide');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.agents_management WHERE id = p_agent_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent introuvable');
  END IF;

  IF v_request_role <> 'service_role'
     AND NOT EXISTS (
       SELECT 1
       FROM public.agents_management am
       JOIN public.pdg_management pm ON pm.id = am.pdg_id
       WHERE am.id = p_agent_id
         AND pm.user_id = auth.uid()
         AND pm.is_active = true
     ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vous n''avez pas les permissions pour modifier cet agent');
  END IF;

  IF COALESCE(p_permissions, '{}'::jsonb) ? 'create_sub_agents' THEN
    v_can_create_sub_agents := (p_permissions->>'create_sub_agents')::boolean;

    UPDATE public.agents_management
    SET can_create_sub_agent = v_can_create_sub_agents,
        updated_at = NOW()
    WHERE id = p_agent_id;
  END IF;

  UPDATE public.agent_permissions
  SET permission_value = false,
      updated_at = NOW()
  WHERE agent_id = p_agent_id
    AND permission_key <> 'create_sub_agents';

  FOR v_key, v_value_text IN
    SELECT key, value
    FROM jsonb_each_text(COALESCE(p_permissions, '{}'::jsonb))
  LOOP
    IF v_key = 'create_sub_agents' THEN
      CONTINUE;
    END IF;

    INSERT INTO public.agent_permissions (
      agent_id,
      permission_key,
      permission_value,
      updated_at
    ) VALUES (
      p_agent_id,
      v_key,
      v_value_text::boolean,
      NOW()
    )
    ON CONFLICT (agent_id, permission_key)
    DO UPDATE SET
      permission_value = EXCLUDED.permission_value,
      updated_at = NOW();
  END LOOP;

  RETURN jsonb_build_object('success', true, 'message', 'Permissions mises a jour avec succes');
END;
$$;

REVOKE ALL ON FUNCTION public.set_agent_permissions(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_agent_permissions(uuid, jsonb) TO authenticated, service_role;
