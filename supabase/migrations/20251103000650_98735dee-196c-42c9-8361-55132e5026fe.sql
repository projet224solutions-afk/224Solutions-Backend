-- Table pour les transactions escrow
CREATE TABLE IF NOT EXISTS public.escrow_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id TEXT NOT NULL,
  payer_id UUID NOT NULL REFERENCES auth.users(id),
  receiver_id UUID NOT NULL REFERENCES auth.users(id),
  amount DECIMAL(15,2) NOT NULL CHECK (amount > 0),
  currency TEXT DEFAULT 'GNF',
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'released', 'refunded', 'dispute')),
  commission_percent DECIMAL(5,2) DEFAULT 0,
  commission_amount DECIMAL(15,2) DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.escrow_transactions ENABLE ROW LEVEL SECURITY;

-- Policies
CREATE POLICY "Users can view their escrow transactions"
ON public.escrow_transactions
FOR SELECT
TO authenticated
USING (auth.uid() = payer_id OR auth.uid() = receiver_id);

CREATE POLICY "Users can create escrow transactions"
ON public.escrow_transactions
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = payer_id);

-- Index pour les recherches
CREATE INDEX idx_escrow_order_id ON public.escrow_transactions(order_id);
CREATE INDEX idx_escrow_payer ON public.escrow_transactions(payer_id);
CREATE INDEX idx_escrow_receiver ON public.escrow_transactions(receiver_id);
CREATE INDEX idx_escrow_status ON public.escrow_transactions(status);

-- Fonction pour initier un escrow
CREATE OR REPLACE FUNCTION initiate_escrow(
  p_order_id TEXT,
  p_payer_id UUID,
  p_receiver_id UUID,
  p_amount DECIMAL,
  p_currency TEXT DEFAULT 'GNF'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_escrow_id UUID;
BEGIN
  -- Créer la transaction escrow
  INSERT INTO escrow_transactions (order_id, payer_id, receiver_id, amount, currency, status)
  VALUES (p_order_id, p_payer_id, p_receiver_id, p_amount, p_currency, 'pending')
  RETURNING id INTO v_escrow_id;
  
  RETURN v_escrow_id;
END;
$$;

-- Fonction pour libérer un escrow
CREATE OR REPLACE FUNCTION release_escrow(
  p_escrow_id UUID,
  p_commission_percent DECIMAL DEFAULT 0
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_amount DECIMAL;
  v_commission DECIMAL;
BEGIN
  -- Récupérer le montant
  SELECT amount INTO v_amount
  FROM escrow_transactions
  WHERE id = p_escrow_id AND status = 'pending';
  
  IF v_amount IS NULL THEN
    RAISE EXCEPTION 'Transaction escrow introuvable ou déjà traitée';
  END IF;
  
  -- Calculer la commission
  v_commission := v_amount * (p_commission_percent / 100);
  
  -- Mettre à jour la transaction
  UPDATE escrow_transactions
  SET status = 'released',
      commission_percent = p_commission_percent,
      commission_amount = v_commission,
      updated_at = now()
  WHERE id = p_escrow_id;
  
  RETURN TRUE;
END;
$$;

-- Fonction pour rembourser un escrow
CREATE OR REPLACE FUNCTION refund_escrow(p_escrow_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE escrow_transactions
  SET status = 'refunded',
      updated_at = now()
  WHERE id = p_escrow_id AND status = 'pending';
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction escrow introuvable ou déjà traitée';
  END IF;
  
  RETURN TRUE;
END;
$$;

-- Fonction pour contester un escrow
CREATE OR REPLACE FUNCTION dispute_escrow(p_escrow_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE escrow_transactions
  SET status = 'dispute',
      updated_at = now()
  WHERE id = p_escrow_id AND status = 'pending';
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction escrow introuvable ou déjà traitée';
  END IF;
  
  RETURN TRUE;
END;
$$;