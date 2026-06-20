-- Drop all three existing versions of create_escrow_transaction explicitly
DROP FUNCTION IF EXISTS public.create_escrow_transaction(uuid, uuid, numeric, uuid, text, jsonb);
DROP FUNCTION IF EXISTS public.create_escrow_transaction(uuid, uuid, text, numeric, text);
DROP FUNCTION IF EXISTS public.create_escrow_transaction(uuid, uuid, uuid, numeric, text, jsonb);

-- Recreate the function with a single, clean signature
CREATE OR REPLACE FUNCTION public.create_escrow_transaction(
  p_buyer_id uuid,
  p_seller_id uuid,
  p_order_id uuid DEFAULT NULL,
  p_amount numeric DEFAULT 0,
  p_currency text DEFAULT 'GNF',
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow_id uuid;
  v_buyer_wallet_id uuid;
  v_seller_wallet_id uuid;
  v_buyer_balance numeric;
BEGIN
  -- Validate input
  IF p_buyer_id IS NULL OR p_seller_id IS NULL THEN
    RAISE EXCEPTION 'buyer_id and seller_id are required';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than 0';
  END IF;

  -- Get or create wallets for both users
  SELECT id INTO v_buyer_wallet_id
  FROM public.wallets
  WHERE user_id = p_buyer_id AND currency = p_currency;

  IF v_buyer_wallet_id IS NULL THEN
    INSERT INTO public.wallets (user_id, balance, currency)
    VALUES (p_buyer_id, 0, p_currency)
    RETURNING id INTO v_buyer_wallet_id;
  END IF;

  SELECT id INTO v_seller_wallet_id
  FROM public.wallets
  WHERE user_id = p_seller_id AND currency = p_currency;

  IF v_seller_wallet_id IS NULL THEN
    INSERT INTO public.wallets (user_id, balance, currency)
    VALUES (p_seller_id, 0, p_currency)
    RETURNING id INTO v_seller_wallet_id;
  END IF;

  -- Check buyer has sufficient balance
  SELECT balance INTO v_buyer_balance
  FROM public.wallets
  WHERE id = v_buyer_wallet_id;

  IF v_buyer_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient balance. Required: %, Available: %', p_amount, v_buyer_balance;
  END IF;

  -- Create escrow transaction
  INSERT INTO public.escrow_transactions (
    order_id,
    payer_id,
    receiver_id,
    amount,
    currency,
    status,
    metadata
  )
  VALUES (
    p_order_id,
    p_buyer_id,
    p_seller_id,
    p_amount,
    p_currency,
    'held',
    p_metadata
  )
  RETURNING id INTO v_escrow_id;

  -- Block funds from buyer's wallet
  UPDATE public.wallets
  SET balance = balance - p_amount
  WHERE id = v_buyer_wallet_id;

  -- Log the escrow creation
  INSERT INTO public.escrow_logs (
    escrow_id,
    action,
    performed_by,
    note,
    metadata
  )
  VALUES (
    v_escrow_id,
    'created',
    p_buyer_id,
    'Escrow created and funds blocked',
    jsonb_build_object(
      'amount', p_amount,
      'currency', p_currency,
      'buyer_id', p_buyer_id,
      'seller_id', p_seller_id
    )
  );

  RETURN v_escrow_id;
END;
$$;