-- ============================================================================
-- MODÈLE COMMISSION — MARKETPLACE : l'agent CRÉATEUR (vendeur) touche, pas l'acheteur
-- ----------------------------------------------------------------------------
-- Décision Thierno : la commission agent va à l'agent qui a créé le service (=le
-- VENDEUR), sur les achats marketplace. Ces 2 fonctions de paiement créditaient
-- l'agent de l'ACHETEUR. On change UNIQUEMENT le destinataire de
-- credit_agent_commission (acheteur → vendeur) ; TOUT le reste est identique.
--   • process_successful_payment  : v_transaction.buyer_id → v_transaction.seller_id
--   • process_wallet_order_payment : p_user_id            → v_vendor_user_id
-- NB : process_wallet_order_payment ampute le vendeur (v_vendor_net = montant − frais).
--      C'est le modèle prix marketplace historique (hors périmètre de ce correctif ;
--      flux canonique = create_order_core). Non modifié ici — seul l'agent change.
-- ============================================================================

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

  -- ✅ Commission AGENT au CRÉATEUR (le vendeur), et non à l'acheteur.
  v_commission_result := public.credit_agent_commission(
    v_transaction.seller_id,
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

  -- ✅ Commission AGENT au CRÉATEUR (le vendeur v_vendor_user_id), et non à l'acheteur (p_user_id).
  v_commission_result := public.credit_agent_commission(
    v_vendor_user_id,
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

SELECT 'Commission agent marketplace : créditée au vendeur (créateur), plus à l''acheteur.' AS status;
