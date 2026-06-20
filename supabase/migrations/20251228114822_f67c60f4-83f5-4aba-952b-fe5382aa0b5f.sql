-- Table pour les transactions de carte virtuelle
CREATE TABLE public.card_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  card_id UUID NOT NULL REFERENCES public.virtual_cards(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  wallet_id UUID NOT NULL REFERENCES public.wallets(id) ON DELETE CASCADE,
  amount DECIMAL(15,2) NOT NULL CHECK (amount > 0),
  currency VARCHAR(10) DEFAULT 'GNF',
  merchant_name VARCHAR(255) NOT NULL,
  merchant_category VARCHAR(100),
  transaction_type VARCHAR(50) NOT NULL DEFAULT 'purchase',
  status VARCHAR(50) NOT NULL DEFAULT 'completed',
  reference_code VARCHAR(100) UNIQUE NOT NULL,
  description TEXT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index pour les requêtes fréquentes
CREATE INDEX idx_card_transactions_card_id ON public.card_transactions(card_id);
CREATE INDEX idx_card_transactions_user_id ON public.card_transactions(user_id);
CREATE INDEX idx_card_transactions_created_at ON public.card_transactions(created_at DESC);

-- Enable RLS
ALTER TABLE public.card_transactions ENABLE ROW LEVEL SECURITY;

-- Policies
CREATE POLICY "Users can view their own card transactions"
ON public.card_transactions FOR SELECT
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own card transactions"
ON public.card_transactions FOR INSERT
WITH CHECK (auth.uid() = user_id);

-- Ajouter des colonnes pour le suivi des dépenses sur virtual_cards
ALTER TABLE public.virtual_cards 
ADD COLUMN IF NOT EXISTS daily_spent DECIMAL(15,2) DEFAULT 0,
ADD COLUMN IF NOT EXISTS monthly_spent DECIMAL(15,2) DEFAULT 0,
ADD COLUMN IF NOT EXISTS last_daily_reset TIMESTAMPTZ DEFAULT now(),
ADD COLUMN IF NOT EXISTS last_monthly_reset TIMESTAMPTZ DEFAULT now(),
ADD COLUMN IF NOT EXISTS total_spent DECIMAL(15,2) DEFAULT 0,
ADD COLUMN IF NOT EXISTS transaction_count INTEGER DEFAULT 0;

-- Fonction pour traiter un paiement par carte virtuelle
CREATE OR REPLACE FUNCTION process_card_payment(
  p_card_id UUID,
  p_amount DECIMAL,
  p_merchant_name VARCHAR,
  p_merchant_category VARCHAR DEFAULT NULL,
  p_description TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_card RECORD;
  v_wallet RECORD;
  v_user_id UUID;
  v_reference_code VARCHAR;
  v_transaction_id UUID;
  v_current_date DATE;
  v_current_month DATE;
BEGIN
  -- Récupérer les infos de la carte
  SELECT * INTO v_card FROM virtual_cards WHERE id = p_card_id;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Carte non trouvée');
  END IF;
  
  v_user_id := v_card.user_id;
  v_current_date := CURRENT_DATE;
  v_current_month := DATE_TRUNC('month', CURRENT_DATE);
  
  -- Vérifier que l'utilisateur est authentifié
  IF auth.uid() IS NULL OR auth.uid() != v_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Non autorisé');
  END IF;
  
  -- Vérifier le statut de la carte
  IF v_card.status != 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Carte inactive ou bloquée');
  END IF;
  
  -- Vérifier la date d'expiration
  IF v_card.expiry_date < TO_CHAR(CURRENT_DATE, 'MM/YY') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Carte expirée');
  END IF;
  
  -- Réinitialiser les compteurs si nécessaire
  IF v_card.last_daily_reset::DATE < v_current_date THEN
    UPDATE virtual_cards 
    SET daily_spent = 0, last_daily_reset = now() 
    WHERE id = p_card_id;
    v_card.daily_spent := 0;
  END IF;
  
  IF DATE_TRUNC('month', v_card.last_monthly_reset) < v_current_month THEN
    UPDATE virtual_cards 
    SET monthly_spent = 0, last_monthly_reset = now() 
    WHERE id = p_card_id;
    v_card.monthly_spent := 0;
  END IF;
  
  -- Vérifier les limites
  IF v_card.daily_limit IS NOT NULL AND (v_card.daily_spent + p_amount) > v_card.daily_limit THEN
    RETURN jsonb_build_object(
      'success', false, 
      'error', 'Limite journalière dépassée',
      'daily_limit', v_card.daily_limit,
      'daily_spent', v_card.daily_spent,
      'remaining', v_card.daily_limit - v_card.daily_spent
    );
  END IF;
  
  IF v_card.monthly_limit IS NOT NULL AND (v_card.monthly_spent + p_amount) > v_card.monthly_limit THEN
    RETURN jsonb_build_object(
      'success', false, 
      'error', 'Limite mensuelle dépassée',
      'monthly_limit', v_card.monthly_limit,
      'monthly_spent', v_card.monthly_spent,
      'remaining', v_card.monthly_limit - v_card.monthly_spent
    );
  END IF;
  
  -- Récupérer le wallet de l'utilisateur
  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_user_id AND currency = 'GNF' LIMIT 1;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet non trouvé');
  END IF;
  
  -- Vérifier le solde
  IF v_wallet.balance < p_amount THEN
    RETURN jsonb_build_object(
      'success', false, 
      'error', 'Solde insuffisant',
      'balance', v_wallet.balance,
      'required', p_amount
    );
  END IF;
  
  -- Générer un code de référence unique
  v_reference_code := 'TXN-' || UPPER(SUBSTRING(gen_random_uuid()::TEXT, 1, 8)) || '-' || TO_CHAR(now(), 'YYYYMMDD');
  
  -- Débiter le wallet
  UPDATE wallets 
  SET balance = balance - p_amount, updated_at = now() 
  WHERE id = v_wallet.id;
  
  -- Créer la transaction
  INSERT INTO card_transactions (
    card_id, user_id, wallet_id, amount, merchant_name, 
    merchant_category, description, reference_code, status
  ) VALUES (
    p_card_id, v_user_id, v_wallet.id, p_amount, p_merchant_name,
    p_merchant_category, p_description, v_reference_code, 'completed'
  ) RETURNING id INTO v_transaction_id;
  
  -- Mettre à jour les compteurs de la carte
  UPDATE virtual_cards 
  SET 
    daily_spent = daily_spent + p_amount,
    monthly_spent = monthly_spent + p_amount,
    total_spent = total_spent + p_amount,
    transaction_count = transaction_count + 1
  WHERE id = p_card_id;
  
  -- Enregistrer dans l'historique des transactions wallet
  INSERT INTO wallet_transactions (
    wallet_id, type, amount, currency, status, description, reference_id
  ) VALUES (
    v_wallet.id, 'card_payment', -p_amount, 'GNF', 'completed',
    'Paiement carte: ' || p_merchant_name, v_transaction_id::TEXT
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'reference_code', v_reference_code,
    'amount', p_amount,
    'new_balance', v_wallet.balance - p_amount,
    'daily_remaining', v_card.daily_limit - v_card.daily_spent - p_amount,
    'monthly_remaining', v_card.monthly_limit - v_card.monthly_spent - p_amount
  );
END;
$$;

-- Fonction pour obtenir les stats de la carte
CREATE OR REPLACE FUNCTION get_card_stats(p_card_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_card RECORD;
  v_today_spent DECIMAL;
  v_month_spent DECIMAL;
  v_last_transactions JSONB;
BEGIN
  SELECT * INTO v_card FROM virtual_cards WHERE id = p_card_id AND user_id = auth.uid();
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Carte non trouvée');
  END IF;
  
  -- Calculer les dépenses du jour
  SELECT COALESCE(SUM(amount), 0) INTO v_today_spent
  FROM card_transactions 
  WHERE card_id = p_card_id AND created_at::DATE = CURRENT_DATE;
  
  -- Calculer les dépenses du mois
  SELECT COALESCE(SUM(amount), 0) INTO v_month_spent
  FROM card_transactions 
  WHERE card_id = p_card_id AND DATE_TRUNC('month', created_at) = DATE_TRUNC('month', CURRENT_DATE);
  
  -- Dernières transactions
  SELECT COALESCE(jsonb_agg(t ORDER BY t.created_at DESC), '[]'::jsonb) INTO v_last_transactions
  FROM (
    SELECT id, amount, merchant_name, merchant_category, status, created_at, reference_code
    FROM card_transactions 
    WHERE card_id = p_card_id
    ORDER BY created_at DESC
    LIMIT 10
  ) t;
  
  RETURN jsonb_build_object(
    'success', true,
    'card_status', v_card.status,
    'daily_limit', v_card.daily_limit,
    'monthly_limit', v_card.monthly_limit,
    'daily_spent', v_today_spent,
    'monthly_spent', v_month_spent,
    'daily_remaining', GREATEST(0, v_card.daily_limit - v_today_spent),
    'monthly_remaining', GREATEST(0, v_card.monthly_limit - v_month_spent),
    'total_spent', v_card.total_spent,
    'transaction_count', v_card.transaction_count,
    'last_transactions', v_last_transactions
  );
END;
$$;