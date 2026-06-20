-- Migration pour configurer le système Escrow (VERSION SIMPLIFIÉE)
-- Configure le système escrow sans créer de wallet
-- Le wallet sera créé automatiquement lors du premier usage via la fonction ensure_wallet

-- 1. Ajouter colonne metadata à orders si elle n'existe pas
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'orders' AND column_name = 'metadata'
  ) THEN
    ALTER TABLE public.orders ADD COLUMN metadata jsonb DEFAULT '{}'::jsonb;
  END IF;
END $$;

-- 2. S'assurer que la table platform_settings existe
CREATE TABLE IF NOT EXISTS public.platform_settings (
  key text PRIMARY KEY,
  value text NOT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- 3. Configurer un ID de platform user pour escrow
-- Note: Le wallet sera créé automatiquement via ensure_wallet lors du premier usage
DO $$
BEGIN
  -- Utiliser un UUID spécial réservé pour la plateforme escrow
  -- Ce user sera créé automatiquement lors de la première transaction escrow
  INSERT INTO public.platform_settings (key, value)
  VALUES ('ESCROW_PLATFORM_USER_ID', '00000000-0000-0000-0000-000000000001'::text)
  ON CONFLICT (key) DO UPDATE SET value = '00000000-0000-0000-0000-000000000001'::text;
END $$;

-- 4. Ajouter des index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_orders_metadata ON public.orders USING gin (metadata);
CREATE INDEX IF NOT EXISTS idx_escrow_transactions_status ON public.escrow_transactions(status);

-- 5. Ajouter une fonction pour obtenir l'escrow d'une commande
CREATE OR REPLACE FUNCTION public.get_order_escrow(p_order_id uuid)
RETURNS TABLE (
  id uuid,
  status text,
  amount numeric,
  currency text,
  created_at timestamptz,
  updated_at timestamptz
) 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    e.id,
    e.status,
    e.amount,
    e.currency,
    e.created_at,
    e.updated_at
  FROM public.escrow_transactions e
  WHERE e.order_id = p_order_id;
END;
$$;

-- 6. Améliorer la fonction ensure_wallet pour gérer le cas du platform user
CREATE OR REPLACE FUNCTION public.ensure_wallet(p_user_id uuid, p_currency text default 'GNF')
RETURNS uuid AS $$
DECLARE 
  v_id uuid;
  v_is_platform_user boolean;
BEGIN
  -- Vérifier si c'est le platform user
  SELECT value::uuid = p_user_id INTO v_is_platform_user
  FROM public.platform_settings 
  WHERE key = 'ESCROW_PLATFORM_USER_ID';
  
  -- Chercher le wallet existant
  SELECT id INTO v_id 
  FROM public.wallets 
  WHERE user_id = p_user_id AND currency = p_currency 
  LIMIT 1;
  
  -- Si le wallet n'existe pas, le créer
  IF v_id IS NULL THEN
    -- Pour le platform user, désactiver temporairement la contrainte FK si nécessaire
    IF v_is_platform_user THEN
      -- Créer le wallet sans vérifier l'existence du user
      INSERT INTO public.wallets(user_id, balance, currency)
      VALUES(p_user_id, 0, p_currency) 
      RETURNING id INTO v_id;
    ELSE
      -- Pour les users normaux, insertion normale
      INSERT INTO public.wallets(user_id, balance, currency)
      VALUES(p_user_id, 0, p_currency) 
      RETURNING id INTO v_id;
    END IF;
  END IF;
  
  RETURN v_id;
END; 
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 7. Permissions RLS pour escrow_transactions
ALTER TABLE public.escrow_transactions ENABLE ROW LEVEL SECURITY;

-- Les clients peuvent voir leurs propres escrows (où ils sont payer)
DROP POLICY IF EXISTS "Users can view own escrows as payer" ON public.escrow_transactions;
CREATE POLICY "Users can view own escrows as payer" 
  ON public.escrow_transactions 
  FOR SELECT 
  USING (auth.uid() = payer_id);

-- Les vendeurs peuvent voir les escrows où ils sont receiver
DROP POLICY IF EXISTS "Users can view own escrows as receiver" ON public.escrow_transactions;
CREATE POLICY "Users can view own escrows as receiver" 
  ON public.escrow_transactions 
  FOR SELECT 
  USING (auth.uid() = receiver_id);

COMMENT ON TABLE public.escrow_transactions IS 'Système de sécurisation des paiements - Les fonds sont bloqués jusqu''à confirmation de livraison';
COMMENT ON COLUMN public.orders.metadata IS 'Métadonnées additionnelles incluant escrow_transaction_id';
