-- =====================================================
-- SYSTÈME DE PAIEMENT DJOMY PROFESSIONNEL 224SOLUTIONS
-- Marketplace avec fonds bloqués et libération admin
-- =====================================================

-- Table des transactions Djomy complète
CREATE TABLE IF NOT EXISTS public.djomy_transactions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  order_id TEXT NOT NULL,
  user_id UUID REFERENCES auth.users(id),
  vendor_id UUID,
  amount DECIMAL(15,2) NOT NULL CHECK (amount > 0),
  currency TEXT NOT NULL DEFAULT 'GNF',
  payment_method TEXT NOT NULL CHECK (payment_method IN ('OM', 'MOMO', 'KULU', 'VISA', 'MASTERCARD')),
  status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'PROCESSING', 'SUCCESS', 'FAILED', 'CANCELLED', 'TIMEOUT', 'REFUNDED')),
  djomy_transaction_id TEXT UNIQUE,
  payer_phone TEXT NOT NULL,
  payer_name TEXT,
  country_code TEXT DEFAULT 'GN',
  fees DECIMAL(15,2) DEFAULT 0,
  received_amount DECIMAL(15,2),
  description TEXT,
  metadata JSONB DEFAULT '{}',
  djomy_response JSONB,
  error_message TEXT,
  ip_address TEXT,
  user_agent TEXT,
  idempotency_key TEXT UNIQUE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  completed_at TIMESTAMP WITH TIME ZONE
);

-- Index pour performance
CREATE INDEX IF NOT EXISTS idx_djomy_transactions_user ON public.djomy_transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_djomy_transactions_vendor ON public.djomy_transactions(vendor_id);
CREATE INDEX IF NOT EXISTS idx_djomy_transactions_status ON public.djomy_transactions(status);
CREATE INDEX IF NOT EXISTS idx_djomy_transactions_created ON public.djomy_transactions(created_at);
CREATE INDEX IF NOT EXISTS idx_djomy_transactions_djomy_id ON public.djomy_transactions(djomy_transaction_id);
CREATE INDEX IF NOT EXISTS idx_djomy_transactions_order ON public.djomy_transactions(order_id);

-- Table des fonds bloqués vendeur
CREATE TABLE IF NOT EXISTS public.vendor_blocked_funds (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL,
  transaction_id UUID NOT NULL REFERENCES public.djomy_transactions(id),
  amount DECIMAL(15,2) NOT NULL CHECK (amount > 0),
  currency TEXT NOT NULL DEFAULT 'GNF',
  status TEXT NOT NULL DEFAULT 'BLOCKED' CHECK (status IN ('BLOCKED', 'RELEASED', 'REFUNDED', 'DISPUTED')),
  blocked_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  released_at TIMESTAMP WITH TIME ZONE,
  released_by UUID,
  release_reason TEXT,
  auto_release_date TIMESTAMP WITH TIME ZONE,
  metadata JSONB DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_vendor_blocked_funds_vendor ON public.vendor_blocked_funds(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_blocked_funds_status ON public.vendor_blocked_funds(status);
CREATE INDEX IF NOT EXISTS idx_vendor_blocked_funds_transaction ON public.vendor_blocked_funds(transaction_id);

-- Table des logs admin
CREATE TABLE IF NOT EXISTS public.admin_action_logs (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  admin_id UUID NOT NULL,
  action_type TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id UUID NOT NULL,
  old_value JSONB,
  new_value JSONB,
  reason TEXT,
  ip_address TEXT,
  user_agent TEXT,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_action_logs_admin ON public.admin_action_logs(admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_action_logs_action ON public.admin_action_logs(action_type);
CREATE INDEX IF NOT EXISTS idx_admin_action_logs_target ON public.admin_action_logs(target_type, target_id);

-- Table des logs de requêtes Djomy (pour traçabilité)
CREATE TABLE IF NOT EXISTS public.djomy_api_logs (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  request_type TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  request_payload JSONB,
  response_status INTEGER,
  response_payload JSONB,
  duration_ms INTEGER,
  error_message TEXT,
  transaction_id UUID REFERENCES public.djomy_transactions(id),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_djomy_api_logs_transaction ON public.djomy_api_logs(transaction_id);
CREATE INDEX IF NOT EXISTS idx_djomy_api_logs_created ON public.djomy_api_logs(created_at);

-- Enable RLS
ALTER TABLE public.djomy_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_blocked_funds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_action_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.djomy_api_logs ENABLE ROW LEVEL SECURITY;

-- Policies pour djomy_transactions
CREATE POLICY "djomy_tx_users_view_own"
ON public.djomy_transactions FOR SELECT
USING (auth.uid() = user_id);

CREATE POLICY "djomy_tx_vendors_view_own"
ON public.djomy_transactions FOR SELECT
USING (auth.uid() = vendor_id);

CREATE POLICY "djomy_tx_admins_all"
ON public.djomy_transactions FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM public.profiles 
    WHERE id = auth.uid() AND role IN ('admin', 'ceo')
  )
);

-- Policies pour vendor_blocked_funds
CREATE POLICY "blocked_funds_vendor_view"
ON public.vendor_blocked_funds FOR SELECT
USING (auth.uid() = vendor_id);

CREATE POLICY "blocked_funds_admin_all"
ON public.vendor_blocked_funds FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM public.profiles 
    WHERE id = auth.uid() AND role IN ('admin', 'ceo')
  )
);

-- Policies pour admin action logs
CREATE POLICY "admin_logs_view"
ON public.admin_action_logs FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles 
    WHERE id = auth.uid() AND role IN ('admin', 'ceo')
  )
);

-- Policies pour API logs (admin only)
CREATE POLICY "api_logs_view"
ON public.djomy_api_logs FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles 
    WHERE id = auth.uid() AND role IN ('admin', 'ceo')
  )
);

-- Trigger pour updated_at
CREATE TRIGGER update_djomy_transactions_updated_at
BEFORE UPDATE ON public.djomy_transactions
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Fonction pour libérer les fonds vendeur
CREATE OR REPLACE FUNCTION public.release_vendor_funds(
  p_blocked_fund_id UUID,
  p_admin_id UUID,
  p_reason TEXT DEFAULT 'Libération manuelle par admin'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_blocked_fund RECORD;
  v_vendor_wallet RECORD;
BEGIN
  -- Vérifier que l'admin a le droit
  IF NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = p_admin_id AND role IN ('admin', 'ceo')
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Unauthorized: Admin role required');
  END IF;

  -- Récupérer les fonds bloqués
  SELECT * INTO v_blocked_fund
  FROM vendor_blocked_funds
  WHERE id = p_blocked_fund_id AND status = 'BLOCKED'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Blocked funds not found or already released');
  END IF;

  -- Mettre à jour le statut des fonds bloqués
  UPDATE vendor_blocked_funds
  SET 
    status = 'RELEASED',
    released_at = now(),
    released_by = p_admin_id,
    release_reason = p_reason
  WHERE id = p_blocked_fund_id;

  -- Créditer le wallet vendeur
  SELECT * INTO v_vendor_wallet
  FROM wallets
  WHERE user_id = v_blocked_fund.vendor_id
  FOR UPDATE;

  IF FOUND THEN
    UPDATE wallets
    SET 
      balance = balance + v_blocked_fund.amount,
      updated_at = now()
    WHERE id = v_vendor_wallet.id;

    -- Créer la transaction wallet
    INSERT INTO wallet_transactions (
      wallet_id, user_id, type, amount, description, status, reference, metadata
    ) VALUES (
      v_vendor_wallet.id,
      v_blocked_fund.vendor_id,
      'deposit',
      v_blocked_fund.amount,
      'Libération de fonds - ' || p_reason,
      'completed',
      v_blocked_fund.transaction_id::TEXT,
      jsonb_build_object(
        'source', 'blocked_funds_release',
        'blocked_fund_id', p_blocked_fund_id,
        'released_by', p_admin_id
      )
    );
  ELSE
    -- Créer le wallet si inexistant
    INSERT INTO wallets (user_id, balance, currency)
    VALUES (v_blocked_fund.vendor_id, v_blocked_fund.amount, v_blocked_fund.currency)
    ON CONFLICT (user_id) DO UPDATE
    SET balance = wallets.balance + v_blocked_fund.amount;
  END IF;

  -- Log l'action admin
  INSERT INTO admin_action_logs (
    admin_id, action_type, target_type, target_id, 
    old_value, new_value, reason
  ) VALUES (
    p_admin_id,
    'RELEASE_FUNDS',
    'vendor_blocked_funds',
    p_blocked_fund_id,
    jsonb_build_object('status', 'BLOCKED'),
    jsonb_build_object('status', 'RELEASED', 'amount', v_blocked_fund.amount),
    p_reason
  );

  RETURN jsonb_build_object(
    'success', true,
    'released_amount', v_blocked_fund.amount,
    'vendor_id', v_blocked_fund.vendor_id
  );
END;
$$;

-- Fonction pour traiter le webhook et bloquer les fonds
CREATE OR REPLACE FUNCTION public.process_djomy_success(
  p_transaction_id UUID,
  p_djomy_response JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_transaction RECORD;
  v_received_amount DECIMAL;
BEGIN
  -- Récupérer la transaction
  SELECT * INTO v_transaction
  FROM djomy_transactions
  WHERE id = p_transaction_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transaction not found');
  END IF;

  IF v_transaction.status = 'SUCCESS' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transaction already processed');
  END IF;

  v_received_amount := COALESCE(
    (p_djomy_response->>'receivedAmount')::DECIMAL,
    (p_djomy_response->>'paidAmount')::DECIMAL,
    v_transaction.amount
  );

  -- Mettre à jour la transaction
  UPDATE djomy_transactions
  SET 
    status = 'SUCCESS',
    djomy_response = p_djomy_response,
    received_amount = v_received_amount,
    fees = COALESCE((p_djomy_response->>'fees')::DECIMAL, 0),
    completed_at = now(),
    updated_at = now()
  WHERE id = p_transaction_id;

  -- Si vendor_id existe, bloquer les fonds
  IF v_transaction.vendor_id IS NOT NULL THEN
    INSERT INTO vendor_blocked_funds (
      vendor_id, transaction_id, amount, currency, 
      auto_release_date, metadata
    ) VALUES (
      v_transaction.vendor_id,
      p_transaction_id,
      v_received_amount,
      v_transaction.currency,
      now() + INTERVAL '7 days',
      jsonb_build_object(
        'order_id', v_transaction.order_id,
        'payment_method', v_transaction.payment_method
      )
    );
  ELSE
    -- Pas de vendeur: créditer directement le wallet utilisateur
    IF v_transaction.user_id IS NOT NULL THEN
      INSERT INTO wallet_transactions (
        wallet_id, user_id, type, amount, description, status, reference
      )
      SELECT 
        w.id, v_transaction.user_id, 'deposit', v_received_amount,
        'Recharge Djomy - ' || v_transaction.payment_method, 'completed',
        p_transaction_id::TEXT
      FROM wallets w WHERE w.user_id = v_transaction.user_id;

      UPDATE wallets
      SET balance = balance + v_received_amount
      WHERE user_id = v_transaction.user_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'amount', v_received_amount,
    'vendor_funds_blocked', v_transaction.vendor_id IS NOT NULL
  );
END;
$$;