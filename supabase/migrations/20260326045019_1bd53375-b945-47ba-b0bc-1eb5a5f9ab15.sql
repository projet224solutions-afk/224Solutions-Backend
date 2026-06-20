-- PHASE 4: Idempotency Keys + Stock RPC Functions

-- 1. Table d'idempotence pour prévenir les doubles créations
CREATE TABLE IF NOT EXISTS public.idempotency_keys (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text NOT NULL UNIQUE,
  method text NOT NULL,
  path text NOT NULL,
  response_body jsonb,
  response_status integer DEFAULT 200,
  created_at timestamptz DEFAULT now(),
  expires_at timestamptz NOT NULL
);

ALTER TABLE public.idempotency_keys ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role only" ON public.idempotency_keys
  FOR ALL USING (false);

CREATE INDEX idx_idempotency_keys_expires ON public.idempotency_keys(expires_at);

-- 2. RPC: Décrémentation atomique du stock
CREATE OR REPLACE FUNCTION public.decrement_product_stock(
  p_product_id uuid,
  p_quantity integer
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE products
  SET stock_quantity = GREATEST(0, COALESCE(stock_quantity, 0) - p_quantity),
      updated_at = now()
  WHERE id = p_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product % not found', p_product_id;
  END IF;
END;
$$;

-- 3. RPC: Incrémentation atomique du stock (pour annulations/retours)
CREATE OR REPLACE FUNCTION public.increment_product_stock(
  p_product_id uuid,
  p_quantity integer
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE products
  SET stock_quantity = COALESCE(stock_quantity, 0) + p_quantity,
      updated_at = now()
  WHERE id = p_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product % not found', p_product_id;
  END IF;
END;
$$;