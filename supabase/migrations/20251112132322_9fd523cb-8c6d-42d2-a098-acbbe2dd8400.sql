-- Migration: Complete Escrow System 224SOLUTIONS (Fixed)
-- Supprime et recrée les tables et fonctions escrow

-- 1. Supprimer les anciennes fonctions si elles existent
DROP FUNCTION IF EXISTS public.refund_escrow_funds(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.release_escrow_funds(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.create_escrow_transaction(uuid, uuid, uuid, decimal, text, jsonb);
DROP FUNCTION IF EXISTS public.get_escrow_stats(timestamp with time zone, timestamp with time zone);

-- 2. Créer la table escrow_transactions si elle n'existe pas
CREATE TABLE IF NOT EXISTS public.escrow_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  buyer_id UUID NOT NULL REFERENCES auth.users(id),
  seller_id UUID NOT NULL REFERENCES auth.users(id),
  order_id UUID REFERENCES public.orders(id),
  amount DECIMAL(15, 2) NOT NULL,
  currency TEXT NOT NULL DEFAULT 'GNF',
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'held', 'released', 'refunded')),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  released_at TIMESTAMP WITH TIME ZONE,
  refunded_at TIMESTAMP WITH TIME ZONE,
  notes TEXT,
  admin_action TEXT,
  admin_id UUID REFERENCES auth.users(id),
  metadata JSONB DEFAULT '{}'::jsonb
);

-- 3. Créer la table escrow_action_logs
CREATE TABLE IF NOT EXISTS public.escrow_action_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escrow_id UUID NOT NULL REFERENCES public.escrow_transactions(id) ON DELETE CASCADE,
  action_type TEXT NOT NULL CHECK (action_type IN ('created', 'held', 'released', 'refunded', 'disputed')),
  performed_by UUID REFERENCES auth.users(id),
  performed_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  notes TEXT,
  user_agent TEXT,
  ip_address TEXT,
  metadata JSONB DEFAULT '{}'::jsonb
);

-- 4. Créer les index
CREATE INDEX IF NOT EXISTS idx_escrow_buyer ON public.escrow_transactions(buyer_id);
CREATE INDEX IF NOT EXISTS idx_escrow_seller ON public.escrow_transactions(seller_id);
CREATE INDEX IF NOT EXISTS idx_escrow_order ON public.escrow_transactions(order_id);
CREATE INDEX IF NOT EXISTS idx_escrow_status ON public.escrow_transactions(status);
CREATE INDEX IF NOT EXISTS idx_escrow_created ON public.escrow_transactions(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_escrow_logs_escrow ON public.escrow_action_logs(escrow_id);

-- 5. Activer RLS
ALTER TABLE public.escrow_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.escrow_action_logs ENABLE ROW LEVEL SECURITY;

-- 6. Politiques RLS escrow_transactions
DROP POLICY IF EXISTS "Users can view their own escrow transactions" ON public.escrow_transactions;
CREATE POLICY "Users can view their own escrow transactions"
ON public.escrow_transactions FOR SELECT
USING (auth.uid() = buyer_id OR auth.uid() = seller_id OR has_role(auth.uid(), 'admin'::user_role));

DROP POLICY IF EXISTS "Service role can manage escrow" ON public.escrow_transactions;
CREATE POLICY "Service role can manage escrow"
ON public.escrow_transactions FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- 7. Politiques RLS escrow_action_logs
DROP POLICY IF EXISTS "Users can view logs of their transactions" ON public.escrow_action_logs;
CREATE POLICY "Users can view logs of their transactions"
ON public.escrow_action_logs FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.escrow_transactions
    WHERE id = escrow_action_logs.escrow_id
    AND (buyer_id = auth.uid() OR seller_id = auth.uid() OR has_role(auth.uid(), 'admin'::user_role))
  )
);

DROP POLICY IF EXISTS "Service role can manage logs" ON public.escrow_action_logs;
CREATE POLICY "Service role can manage logs"
ON public.escrow_action_logs FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- 8. Fonction: Créer transaction escrow
CREATE FUNCTION public.create_escrow_transaction(
  p_buyer_id UUID,
  p_seller_id UUID,
  p_order_id UUID,
  p_amount DECIMAL,
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
  v_buyer_balance DECIMAL;
BEGIN
  SELECT balance INTO v_buyer_balance
  FROM public.wallets
  WHERE user_id = p_buyer_id AND currency = p_currency;

  IF v_buyer_balance IS NULL THEN
    RAISE EXCEPTION 'Wallet not found for buyer';
  END IF;

  IF v_buyer_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;

  INSERT INTO public.escrow_transactions (
    buyer_id, seller_id, order_id, amount, currency, status, metadata
  )
  VALUES (
    p_buyer_id, p_seller_id, p_order_id, p_amount, p_currency, 'held', p_metadata
  )
  RETURNING id INTO v_escrow_id;

  UPDATE public.wallets
  SET balance = balance - p_amount, updated_at = now()
  WHERE user_id = p_buyer_id AND currency = p_currency;

  INSERT INTO public.escrow_action_logs (escrow_id, action_type, performed_by, notes)
  VALUES (v_escrow_id, 'held', p_buyer_id, 'Funds blocked in escrow');

  RETURN v_escrow_id;
END;
$$;

-- 9. Fonction: Libérer les fonds
CREATE FUNCTION public.release_escrow_funds(
  p_escrow_id UUID,
  p_admin_id UUID,
  p_notes TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow RECORD;
BEGIN
  IF NOT has_role(p_admin_id, 'admin'::user_role) THEN
    RAISE EXCEPTION 'Only admins can release escrow funds';
  END IF;

  SELECT * INTO v_escrow
  FROM public.escrow_transactions
  WHERE id = p_escrow_id AND status = 'held';

  IF v_escrow IS NULL THEN
    RAISE EXCEPTION 'Escrow not found or not in held status';
  END IF;

  UPDATE public.wallets
  SET balance = balance + v_escrow.amount, updated_at = now()
  WHERE user_id = v_escrow.seller_id AND currency = v_escrow.currency;

  UPDATE public.escrow_transactions
  SET status = 'released', released_at = now(), admin_id = p_admin_id,
      admin_action = 'release', notes = COALESCE(p_notes, notes)
  WHERE id = p_escrow_id;

  INSERT INTO public.escrow_action_logs (escrow_id, action_type, performed_by, notes)
  VALUES (p_escrow_id, 'released', p_admin_id, COALESCE(p_notes, 'Funds released to seller'));

  RETURN TRUE;
END;
$$;

-- 10. Fonction: Rembourser l'acheteur
CREATE FUNCTION public.refund_escrow_funds(
  p_escrow_id UUID,
  p_admin_id UUID,
  p_reason TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow RECORD;
BEGIN
  IF NOT has_role(p_admin_id, 'admin'::user_role) THEN
    RAISE EXCEPTION 'Only admins can refund escrow funds';
  END IF;

  SELECT * INTO v_escrow
  FROM public.escrow_transactions
  WHERE id = p_escrow_id AND status IN ('held', 'pending');

  IF v_escrow IS NULL THEN
    RAISE EXCEPTION 'Escrow not found or cannot be refunded';
  END IF;

  UPDATE public.wallets
  SET balance = balance + v_escrow.amount, updated_at = now()
  WHERE user_id = v_escrow.buyer_id AND currency = v_escrow.currency;

  UPDATE public.escrow_transactions
  SET status = 'refunded', refunded_at = now(), admin_id = p_admin_id,
      admin_action = 'refund', notes = p_reason
  WHERE id = p_escrow_id;

  INSERT INTO public.escrow_action_logs (escrow_id, action_type, performed_by, notes)
  VALUES (p_escrow_id, 'refunded', p_admin_id, p_reason);

  RETURN TRUE;
END;
$$;

-- 11. Fonction: Stats escrow pour dashboard PDG
CREATE FUNCTION public.get_escrow_stats(
  p_start_date TIMESTAMP WITH TIME ZONE DEFAULT NULL,
  p_end_date TIMESTAMP WITH TIME ZONE DEFAULT NULL
)
RETURNS TABLE (
  total_transactions BIGINT,
  total_amount DECIMAL,
  held_count BIGINT,
  held_amount DECIMAL,
  released_count BIGINT,
  released_amount DECIMAL,
  refunded_count BIGINT,
  refunded_amount DECIMAL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    COUNT(*)::BIGINT,
    COALESCE(SUM(amount), 0),
    COUNT(*) FILTER (WHERE status = 'held')::BIGINT,
    COALESCE(SUM(amount) FILTER (WHERE status = 'held'), 0),
    COUNT(*) FILTER (WHERE status = 'released')::BIGINT,
    COALESCE(SUM(amount) FILTER (WHERE status = 'released'), 0),
    COUNT(*) FILTER (WHERE status = 'refunded')::BIGINT,
    COALESCE(SUM(amount) FILTER (WHERE status = 'refunded'), 0)
  FROM public.escrow_transactions
  WHERE (p_start_date IS NULL OR created_at >= p_start_date)
    AND (p_end_date IS NULL OR created_at <= p_end_date);
END;
$$;