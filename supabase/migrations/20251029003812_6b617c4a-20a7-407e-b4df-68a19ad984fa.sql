-- 🔧 CORRECTION POLITIQUES RLS WALLETS
-- Permettre aux utilisateurs de gérer leurs wallets

-- Supprimer les anciennes politiques si elles existent
DROP POLICY IF EXISTS "Users can view their own wallet" ON wallets;
DROP POLICY IF EXISTS "Users can insert their own wallet" ON wallets;
DROP POLICY IF EXISTS "Users can update their own wallet" ON wallets;
DROP POLICY IF EXISTS "Service role can manage all wallets" ON wallets;

-- Créer les nouvelles politiques RLS pour wallets
CREATE POLICY "Users can view their own wallet"
ON wallets FOR SELECT
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own wallet"
ON wallets FOR INSERT
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own wallet"
ON wallets FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

-- Politique pour le service role (edge functions)
CREATE POLICY "Service role can manage all wallets"
ON wallets FOR ALL
USING (auth.role() = 'service_role');

-- S'assurer que RLS est activé
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;

-- Créer un index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_wallets_user_id ON wallets(user_id);
CREATE INDEX IF NOT EXISTS idx_wallets_public_id ON wallets(public_id);