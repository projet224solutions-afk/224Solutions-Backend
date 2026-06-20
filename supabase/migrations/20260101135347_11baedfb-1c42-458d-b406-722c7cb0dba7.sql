-- =====================================================
-- RÉINITIALISATION COMPLÈTE DES SOLDES ET ARCHIVAGE
-- Conserver les données pour audit, remettre soldes à 0
-- =====================================================

-- 1. RÉINITIALISER TOUS LES SOLDES WALLETS À 0
UPDATE public.wallets SET balance = 0, updated_at = now();
UPDATE public.agent_wallets SET balance = 0, updated_at = now();
UPDATE public.bureau_wallets SET balance = 0, updated_at = now();

-- 2. ARCHIVER LES TRANSACTIONS (ajouter colonne is_archived si pas existante)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'enhanced_transactions' AND column_name = 'is_archived'
  ) THEN
    ALTER TABLE public.enhanced_transactions ADD COLUMN is_archived BOOLEAN DEFAULT false;
  END IF;
  
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'wallet_transactions' AND column_name = 'is_archived'
  ) THEN
    ALTER TABLE public.wallet_transactions ADD COLUMN is_archived BOOLEAN DEFAULT false;
  END IF;
  
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'card_transactions' AND column_name = 'is_archived'
  ) THEN
    ALTER TABLE public.card_transactions ADD COLUMN is_archived BOOLEAN DEFAULT false;
  END IF;
END $$;

-- Marquer toutes les transactions existantes comme archivées
UPDATE public.enhanced_transactions SET is_archived = true WHERE is_archived IS NULL OR is_archived = false;
UPDATE public.wallet_transactions SET is_archived = true WHERE is_archived IS NULL OR is_archived = false;
UPDATE public.card_transactions SET is_archived = true WHERE is_archived IS NULL OR is_archived = false;

-- 3. ARCHIVER LES COMMANDES
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'orders' AND column_name = 'is_archived'
  ) THEN
    ALTER TABLE public.orders ADD COLUMN is_archived BOOLEAN DEFAULT false;
  END IF;
END $$;

UPDATE public.orders SET is_archived = true WHERE is_archived IS NULL OR is_archived = false;

-- 4. CRÉER UNE VUE POUR LES TRANSACTIONS ACTIVES (non archivées)
CREATE OR REPLACE VIEW public.active_transactions AS
SELECT * FROM public.enhanced_transactions WHERE is_archived = false;

CREATE OR REPLACE VIEW public.active_orders AS
SELECT * FROM public.orders WHERE is_archived = false;

-- 5. AJOUTER DATE DE RÉINITIALISATION DANS system_settings
INSERT INTO public.system_settings (setting_key, setting_value, description, updated_at)
VALUES ('last_reset_date', to_char(now(), 'YYYY-MM-DD HH24:MI:SS'), 'Date de la dernière réinitialisation des soldes', now())
ON CONFLICT (setting_key) DO UPDATE SET setting_value = to_char(now(), 'YYYY-MM-DD HH24:MI:SS'), updated_at = now();

-- 6. RENFORCER LA SÉCURITÉ RLS SUR LES TABLES SENSIBLES

-- Wallets: seul le propriétaire peut voir son wallet
DROP POLICY IF EXISTS "users_view_own_wallet" ON public.wallets;
CREATE POLICY "users_view_own_wallet" ON public.wallets
FOR SELECT USING (user_id = auth.uid());

DROP POLICY IF EXISTS "service_role_manage_wallets" ON public.wallets;
CREATE POLICY "service_role_manage_wallets" ON public.wallets
FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');

-- Enhanced transactions: seul le propriétaire ou PDG
DROP POLICY IF EXISTS "users_view_own_transactions" ON public.enhanced_transactions;
CREATE POLICY "users_view_own_transactions" ON public.enhanced_transactions
FOR SELECT USING (
  sender_id = auth.uid() 
  OR receiver_id = auth.uid()
  OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
);

-- Orders: vendeur propriétaire uniquement
DROP POLICY IF EXISTS "vendors_view_own_orders" ON public.orders;
CREATE POLICY "vendors_view_own_orders" ON public.orders
FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM vendors v WHERE v.id = orders.vendor_id AND v.user_id = auth.uid()
  )
  OR EXISTS (SELECT 1 FROM pdg_management WHERE user_id = auth.uid())
);