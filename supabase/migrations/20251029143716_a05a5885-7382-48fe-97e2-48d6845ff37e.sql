-- Supprimer toutes les politiques existantes sur wallets
DROP POLICY IF EXISTS "Users can view their own wallet" ON wallets;
DROP POLICY IF EXISTS "Users can manage their wallet" ON wallets;
DROP POLICY IF EXISTS "Users can update their own wallet" ON wallets;
DROP POLICY IF EXISTS "Users can create their own wallet" ON wallets;
DROP POLICY IF EXISTS "Service role full access to wallets" ON wallets;
DROP POLICY IF EXISTS "service_role_all" ON wallets;

-- Recréer les politiques correctes

-- Politique 1: Les utilisateurs peuvent voir leur propre wallet
CREATE POLICY "view_own_wallet"
ON wallets
FOR SELECT
USING (auth.uid() = user_id);

-- Politique 2: Les utilisateurs peuvent créer leur propre wallet
CREATE POLICY "create_own_wallet"
ON wallets
FOR INSERT
WITH CHECK (auth.uid() = user_id);

-- Politique 3: Les utilisateurs peuvent mettre à jour leur propre wallet
CREATE POLICY "update_own_wallet"
ON wallets
FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

-- Politique 4: Service role a accès complet
CREATE POLICY "service_role_wallets"
ON wallets
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');