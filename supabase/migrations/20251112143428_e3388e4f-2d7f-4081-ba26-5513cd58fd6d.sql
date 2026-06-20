-- Fix create_escrow_transaction function with proper parameter ordering
CREATE OR REPLACE FUNCTION public.create_escrow_transaction(
  p_buyer_id UUID,
  p_seller_id UUID,
  p_amount DECIMAL,
  p_order_id UUID DEFAULT NULL,
  p_currency TEXT DEFAULT 'GNF',
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow_id UUID;
BEGIN
  -- Insert escrow transaction with correct column mapping
  INSERT INTO public.escrow_transactions (
    payer_id,           -- Map buyer_id to payer_id
    receiver_id,        -- Map seller_id to receiver_id
    order_id,
    amount,
    currency,
    status,
    metadata,
    buyer_id,           -- Store original buyer_id
    seller_id           -- Store original seller_id
  )
  VALUES (
    p_buyer_id,         -- payer_id
    p_seller_id,        -- receiver_id
    p_order_id,
    p_amount,
    p_currency,
    'held',
    p_metadata,
    p_buyer_id,         -- buyer_id
    p_seller_id         -- seller_id
  )
  RETURNING id INTO v_escrow_id;

  -- Log the creation
  INSERT INTO public.escrow_logs (
    escrow_id,
    action_type,
    performed_by,
    notes
  )
  VALUES (
    v_escrow_id,
    'created',
    p_buyer_id,
    'Escrow transaction created'
  );

  RETURN v_escrow_id;
END;
$$;