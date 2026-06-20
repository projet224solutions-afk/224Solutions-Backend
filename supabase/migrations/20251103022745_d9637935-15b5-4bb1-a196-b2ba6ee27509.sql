-- Nettoyer les politiques RLS en double sur la table wallets
DROP POLICY IF EXISTS "Users can create their wallet" ON public.wallets;
DROP POLICY IF EXISTS "Users can insert their own wallet" ON public.wallets;
DROP POLICY IF EXISTS "create_own_wallet" ON public.wallets;
DROP POLICY IF EXISTS "update_own_wallet" ON public.wallets;
DROP POLICY IF EXISTS "view_own_wallet" ON public.wallets;
DROP POLICY IF EXISTS "Users can update their wallet" ON public.wallets;
DROP POLICY IF EXISTS "Users can view their wallet" ON public.wallets;

-- Créer des politiques RLS simplifiées et claires
CREATE POLICY "allow_users_insert_own_wallet" 
  ON public.wallets 
  FOR INSERT 
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "allow_users_select_own_wallet" 
  ON public.wallets 
  FOR SELECT 
  TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "allow_users_update_own_wallet" 
  ON public.wallets 
  FOR UPDATE 
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- Ajouter des valeurs par défaut pour faciliter les insertions
ALTER TABLE public.wallets 
  ALTER COLUMN balance SET DEFAULT 10000,
  ALTER COLUMN currency SET DEFAULT 'GNF',
  ALTER COLUMN wallet_status SET DEFAULT 'active',
  ALTER COLUMN is_blocked SET DEFAULT false,
  ALTER COLUMN two_factor_enabled SET DEFAULT false,
  ALTER COLUMN total_received SET DEFAULT 0,
  ALTER COLUMN total_sent SET DEFAULT 0,
  ALTER COLUMN daily_limit SET DEFAULT 1000000,
  ALTER COLUMN monthly_limit SET DEFAULT 10000000,
  ALTER COLUMN created_at SET DEFAULT NOW(),
  ALTER COLUMN updated_at SET DEFAULT NOW();