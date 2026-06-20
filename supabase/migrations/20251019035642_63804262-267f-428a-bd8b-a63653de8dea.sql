-- Nettoyer et recréer les politiques RLS pour wallet_transactions et wallets

-- ========== WALLET_TRANSACTIONS ==========

-- Supprimer toutes les anciennes politiques de wallet_transactions
DROP POLICY IF EXISTS "PDG only access wallet_transactions" ON wallet_transactions;
DROP POLICY IF EXISTS "Users can view their own transactions" ON wallet_transactions;
DROP POLICY IF EXISTS "Users can create transactions as sender" ON wallet_transactions;
DROP POLICY IF EXISTS "Users can update their transaction status" ON wallet_transactions;

-- Créer les nouvelles politiques pour wallet_transactions

-- 1. Voir ses propres transactions (en tant qu'expéditeur ou destinataire)
CREATE POLICY "Users can view their own transactions"
ON wallet_transactions
FOR SELECT
TO public
USING (
  EXISTS (
    SELECT 1 FROM wallets 
    WHERE (wallets.id = wallet_transactions.sender_wallet_id 
           OR wallets.id = wallet_transactions.receiver_wallet_id)
    AND wallets.user_id = auth.uid()
  )
);

-- 2. Créer des transactions
CREATE POLICY "Users can create transactions"
ON wallet_transactions
FOR INSERT
TO public
WITH CHECK (
  EXISTS (
    SELECT 1 FROM wallets 
    WHERE wallets.id = wallet_transactions.sender_wallet_id 
    AND wallets.user_id = auth.uid()
  )
  OR 
  EXISTS (
    SELECT 1 FROM wallets 
    WHERE wallets.id = wallet_transactions.receiver_wallet_id 
    AND wallets.user_id = auth.uid()
  )
);

-- 3. Mettre à jour leurs transactions
CREATE POLICY "Users can update their transactions"
ON wallet_transactions
FOR UPDATE
TO public
USING (
  EXISTS (
    SELECT 1 FROM wallets 
    WHERE (wallets.id = wallet_transactions.sender_wallet_id 
           OR wallets.id = wallet_transactions.receiver_wallet_id)
    AND wallets.user_id = auth.uid()
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM wallets 
    WHERE (wallets.id = wallet_transactions.sender_wallet_id 
           OR wallets.id = wallet_transactions.receiver_wallet_id)
    AND wallets.user_id = auth.uid()
  )
);

-- ========== WALLETS ==========

-- Supprimer les anciennes politiques de wallets (sauf service_role)
DROP POLICY IF EXISTS "Users can view their own wallet" ON wallets;
DROP POLICY IF EXISTS "Users can create their own wallet" ON wallets;
DROP POLICY IF EXISTS "Users can update their own wallet" ON wallets;

-- Créer les nouvelles politiques pour wallets

-- 1. Voir son propre wallet
CREATE POLICY "Users can view their wallet"
ON wallets
FOR SELECT
TO public
USING (user_id = auth.uid());

-- 2. Créer leur wallet (INSERT seulement lors de l'initialisation)
CREATE POLICY "Users can create their wallet"
ON wallets
FOR INSERT
TO public
WITH CHECK (user_id = auth.uid());

-- 3. Mettre à jour leur wallet (pour les transactions)
CREATE POLICY "Users can update their wallet"
ON wallets
FOR UPDATE
TO public
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());