-- ============================================
-- SÉCURITÉ RLS POUR SYSTÈME ESCROW
-- ============================================
-- Date: 04 Décembre 2024
-- Description: Active RLS et crée les politiques de sécurité
-- ============================================

-- ============================================
-- ÉTAPE 1: ACTIVER RLS SUR LES TABLES
-- ============================================

-- Table escrow_transactions
ALTER TABLE IF EXISTS escrow_transactions ENABLE ROW LEVEL SECURITY;

-- Table escrow_logs (si elle existe)
ALTER TABLE IF EXISTS escrow_logs ENABLE ROW LEVEL SECURITY;

-- Table profiles
ALTER TABLE IF EXISTS profiles ENABLE ROW LEVEL SECURITY;

-- ============================================
-- ÉTAPE 2: POLICIES POUR ESCROW_TRANSACTIONS
-- ============================================

-- Supprimer les anciennes policies si elles existent
DROP POLICY IF EXISTS "Users can view their own escrow transactions" ON escrow_transactions;
DROP POLICY IF EXISTS "Users can create escrow transactions as payer" ON escrow_transactions;
DROP POLICY IF EXISTS "Payer can cancel pending escrow transaction" ON escrow_transactions;
DROP POLICY IF EXISTS "Receiver can confirm escrow transaction" ON escrow_transactions;
DROP POLICY IF EXISTS "Service role has full access to escrow transactions" ON escrow_transactions;

-- Policy 1: Les utilisateurs peuvent voir leurs propres transactions
CREATE POLICY "Users can view their own escrow transactions"
ON escrow_transactions
FOR SELECT
USING (
  payer_id = auth.uid() 
  OR receiver_id = auth.uid()
);

-- Policy 2: Les utilisateurs peuvent créer des transactions où ils sont payeurs
CREATE POLICY "Users can create escrow transactions as payer"
ON escrow_transactions
FOR INSERT
WITH CHECK (payer_id = auth.uid());

-- Policy 3: Le payeur peut annuler une transaction en attente
CREATE POLICY "Payer can cancel pending escrow transaction"
ON escrow_transactions
FOR UPDATE
USING (
  payer_id = auth.uid() 
  AND status = 'pending'
)
WITH CHECK (
  payer_id = auth.uid()
  AND status IN ('pending', 'cancelled')
);

-- Policy 4: Le receveur peut confirmer la réception
CREATE POLICY "Receiver can confirm escrow transaction"
ON escrow_transactions
FOR UPDATE
USING (
  receiver_id = auth.uid()
  AND status = 'held'
)
WITH CHECK (
  receiver_id = auth.uid()
  AND status IN ('held', 'completed')
);

-- Policy 5: Service role a accès complet (pour fonctions backend)
CREATE POLICY "Service role has full access to escrow transactions"
ON escrow_transactions
FOR ALL
USING (auth.jwt()->>'role' = 'service_role');

-- ============================================
-- ÉTAPE 3: POLICIES POUR ESCROW_LOGS
-- ============================================

-- Supprimer les anciennes policies si elles existent
DROP POLICY IF EXISTS "Users can view logs of their escrow transactions" ON escrow_logs;
DROP POLICY IF EXISTS "Only system can create escrow logs" ON escrow_logs;
DROP POLICY IF EXISTS "Service role has full access to escrow logs" ON escrow_logs;

-- Policy 1: Les utilisateurs peuvent voir les logs de leurs transactions
CREATE POLICY "Users can view logs of their escrow transactions"
ON escrow_logs
FOR SELECT
USING (
  escrow_transaction_id IN (
    SELECT id FROM escrow_transactions
    WHERE payer_id = auth.uid() OR receiver_id = auth.uid()
  )
);

-- Policy 2: Seul le système peut créer des logs
CREATE POLICY "Only system can create escrow logs"
ON escrow_logs
FOR INSERT
WITH CHECK (auth.jwt()->>'role' = 'service_role');

-- Policy 3: Service role a accès complet
CREATE POLICY "Service role has full access to escrow logs"
ON escrow_logs
FOR ALL
USING (auth.jwt()->>'role' = 'service_role');

-- ============================================
-- ÉTAPE 4: POLICIES POUR PROFILES
-- ============================================

-- Supprimer les anciennes policies si elles existent
DROP POLICY IF EXISTS "Users can view their own profile" ON profiles;
DROP POLICY IF EXISTS "Users can view public profiles" ON profiles;
DROP POLICY IF EXISTS "Users can update their own profile" ON profiles;
DROP POLICY IF EXISTS "Only system can create profiles" ON profiles;
DROP POLICY IF EXISTS "Service role has full access to profiles" ON profiles;

-- Policy 1: Les utilisateurs peuvent voir leur propre profil
CREATE POLICY "Users can view their own profile"
ON profiles
FOR SELECT
USING (id = auth.uid());

-- Policy 2: Les utilisateurs peuvent voir les profils publics
CREATE POLICY "Users can view public profiles"
ON profiles
FOR SELECT
USING (true); -- Tous les profils sont visibles pour recherche

-- Policy 3: Les utilisateurs peuvent mettre à jour leur propre profil
CREATE POLICY "Users can update their own profile"
ON profiles
FOR UPDATE
USING (id = auth.uid())
WITH CHECK (id = auth.uid());

-- Policy 4: Seul le système peut créer des profils
CREATE POLICY "Only system can create profiles"
ON profiles
FOR INSERT
WITH CHECK (id = auth.uid());

-- Policy 5: Service role a accès complet
CREATE POLICY "Service role has full access to profiles"
ON profiles
FOR ALL
USING (auth.jwt()->>'role' = 'service_role');

-- ============================================
-- ÉTAPE 5: POLICIES POUR WALLETS
-- ============================================

-- Activer RLS sur wallets
ALTER TABLE IF EXISTS wallets ENABLE ROW LEVEL SECURITY;

-- Supprimer les anciennes policies si elles existent
DROP POLICY IF EXISTS "Users can view their own wallet" ON wallets;
DROP POLICY IF EXISTS "Only system can modify wallets" ON wallets;

-- Policy 1: Les utilisateurs peuvent voir leur propre wallet
CREATE POLICY "Users can view their own wallet"
ON wallets
FOR SELECT
USING (user_id = auth.uid());

-- Policy 2: Seul le système peut créer/modifier les wallets
CREATE POLICY "Only system can modify wallets"
ON wallets
FOR ALL
USING (auth.jwt()->>'role' = 'service_role');

-- ============================================
-- ÉTAPE 6: POLICIES POUR WALLET_TRANSACTIONS
-- ============================================

-- Activer RLS sur wallet_transactions
ALTER TABLE IF EXISTS wallet_transactions ENABLE ROW LEVEL SECURITY;

-- Supprimer les anciennes policies si elles existent
DROP POLICY IF EXISTS "Users can view their wallet transactions" ON wallet_transactions;
DROP POLICY IF EXISTS "Only system can create wallet transactions" ON wallet_transactions;

-- Policy 1: Les utilisateurs peuvent voir les transactions de leur wallet
CREATE POLICY "Users can view their wallet transactions"
ON wallet_transactions
FOR SELECT
USING (
  wallet_id IN (
    SELECT id FROM wallets WHERE user_id = auth.uid()
  )
);

-- Policy 2: Seul le système peut créer des transactions wallet
CREATE POLICY "Only system can create wallet transactions"
ON wallet_transactions
FOR ALL
USING (auth.jwt()->>'role' = 'service_role');

-- ============================================
-- ÉTAPE 7: POLICIES POUR REVENUS_PDG
-- ============================================

-- Activer RLS sur revenus_pdg
ALTER TABLE IF EXISTS revenus_pdg ENABLE ROW LEVEL SECURITY;

-- Supprimer les anciennes policies si elles existent
DROP POLICY IF EXISTS "Only PDG can view revenus" ON revenus_pdg;
DROP POLICY IF EXISTS "Only system can create revenus PDG" ON revenus_pdg;

-- Policy 1: Seul le PDG peut voir ses revenus
CREATE POLICY "Only PDG can view revenus"
ON revenus_pdg
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid() AND role = 'pdg'
  )
);

-- Policy 2: Seul le système peut créer des revenus PDG
CREATE POLICY "Only system can create revenus PDG"
ON revenus_pdg
FOR ALL
USING (auth.jwt()->>'role' = 'service_role');

-- ============================================
-- ÉTAPE 8: POLICIES POUR SUBSCRIPTIONS
-- ============================================

-- Activer RLS sur subscriptions
ALTER TABLE IF EXISTS subscriptions ENABLE ROW LEVEL SECURITY;

-- Supprimer les anciennes policies si elles existent
DROP POLICY IF EXISTS "Users can view their own subscriptions" ON subscriptions;
DROP POLICY IF EXISTS "Users can create their own subscriptions" ON subscriptions;
DROP POLICY IF EXISTS "Users can update their own subscriptions" ON subscriptions;
DROP POLICY IF EXISTS "Service role has full access to subscriptions" ON subscriptions;

-- Policy 1: Les utilisateurs peuvent voir leurs propres abonnements
CREATE POLICY "Users can view their own subscriptions"
ON subscriptions
FOR SELECT
USING (user_id = auth.uid());

-- Policy 2: Les utilisateurs peuvent créer leurs abonnements
CREATE POLICY "Users can create their own subscriptions"
ON subscriptions
FOR INSERT
WITH CHECK (user_id = auth.uid());

-- Policy 3: Les utilisateurs peuvent modifier leurs abonnements
CREATE POLICY "Users can update their own subscriptions"
ON subscriptions
FOR UPDATE
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- ============================================
-- ÉTAPE 9: POLICIES POUR PRODUCTS
-- ============================================

-- Activer RLS sur products
ALTER TABLE IF EXISTS products ENABLE ROW LEVEL SECURITY;

-- Supprimer les anciennes policies si elles existent
DROP POLICY IF EXISTS "Anyone can view active products" ON products;
DROP POLICY IF EXISTS "Vendors can view their own products" ON products;
DROP POLICY IF EXISTS "Vendors can create products" ON products;
DROP POLICY IF EXISTS "Vendors can update their products" ON products;
DROP POLICY IF EXISTS "Vendors can delete their products" ON products;
DROP POLICY IF EXISTS "Service role has full access to products" ON products;

-- Policy 1: Tout le monde peut voir les produits actifs
CREATE POLICY "Anyone can view active products"
ON products
FOR SELECT
USING (is_active = true);LE ROW LEVEL SECURITY;

-- Policy 1: Tout le monde peut voir les produits actifs
CREATE POLICY "Anyone can view active products"
ON products
FOR SELECT
USING (is_active = true);

-- Policy 2: Les vendeurs peuvent voir tous leurs produits
CREATE POLICY "Vendors can view their own products"
ON products
FOR SELECT
USING (
  vendor_id IN (
    SELECT id FROM vendors WHERE user_id = auth.uid()
  )
);

-- Policy 3: Les vendeurs peuvent créer des produits
CREATE POLICY "Vendors can create products"
ON products
FOR INSERT
WITH CHECK (
  vendor_id IN (
    SELECT id FROM vendors WHERE user_id = auth.uid()
  )
);

-- Policy 4: Les vendeurs peuvent modifier leurs produits
CREATE POLICY "Vendors can update their products"
ON products
FOR UPDATE
USING (
  vendor_id IN (
    SELECT id FROM vendors WHERE user_id = auth.uid()
  )
)
WITH CHECK (
  vendor_id IN (
    SELECT id FROM vendors WHERE user_id = auth.uid()
  )
);

-- Policy 5: Les vendeurs peuvent supprimer leurs produits
CREATE POLICY "Vendors can delete their products"
ON products
FOR DELETE
USING (
  vendor_id IN (
    SELECT id FROM vendors WHERE user_id = auth.uid()
  )
);

-- Policy 6: Service role a accès complet
CREATE POLICY "Service role has full access to products"
ON products
FOR ALL
USING (auth.jwt()->>'role' = 'service_role');

-- ============================================
-- ÉTAPE 10: POLICIES POUR ORDERS
-- ============================================

-- Activer RLS sur orders
ALTER TABLE IF EXISTS orders ENABLE ROW LEVEL SECURITY;

-- Policy 1: Les acheteurs peuvent voir leurs commandes
CREATE POLICY "Buyers can view their orders"
ON orders
FOR SELECT
USING (buyer_id = auth.uid());

-- Policy 2: Les vendeurs peuvent voir les commandes de leurs produits
CREATE POLICY "Vendors can view orders for their products"
ON orders
FOR SELECT
USING (
  vendor_id IN (
    SELECT id FROM vendors WHERE user_id = auth.uid()
  )
);

-- Policy 3: Les acheteurs peuvent créer des commandes
CREATE POLICY "Buyers can create orders"
ON orders
FOR INSERT
WITH CHECK (buyer_id = auth.uid());

-- Policy 4: Les acheteurs peuvent annuler leurs commandes
CREATE POLICY "Buyers can cancel their orders"
ON orders
FOR UPDATE
USING (buyer_id = auth.uid() AND status = 'pending')
WITH CHECK (buyer_id = auth.uid());

-- Policy 5: Les vendeurs peuvent modifier le statut des commandes
CREATE POLICY "Vendors can update order status"
ON orders
FOR UPDATE
USING (
  vendor_id IN (
    SELECT id FROM vendors WHERE user_id = auth.uid()
  )
)
WITH CHECK (
  vendor_id IN (
    SELECT id FROM vendors WHERE user_id = auth.uid()
  )
);

-- Policy 6: Service role a accès complet
CREATE POLICY "Service role has full access to orders"
ON orders
FOR ALL
USING (auth.jwt()->>'role' = 'service_role');

-- ============================================
-- ÉTAPE 11: VERIFICATION DES POLICIES
-- ============================================

-- Fonction pour vérifier les policies actives
CREATE OR REPLACE FUNCTION list_rls_policies()
RETURNS TABLE (
  table_name TEXT,
  policy_name TEXT,
  policy_command TEXT,
  policy_roles TEXT[]
)
LANGUAGE SQL
SECURITY DEFINER
AS $$
  SELECT 
    schemaname || '.' || tablename as table_name,
    policyname as policy_name,
    cmd as policy_command,
    roles as policy_roles
  FROM pg_policies
  WHERE schemaname = 'public'
  ORDER BY tablename, policyname;
$$;

-- ============================================
-- ÉTAPE 12: GRANT PERMISSIONS
-- ============================================

-- Permissions pour authenticated users
GRANT SELECT ON escrow_transactions TO authenticated;
GRANT INSERT ON escrow_transactions TO authenticated;
GRANT UPDATE ON escrow_transactions TO authenticated;

GRANT SELECT ON escrow_logs TO authenticated;

GRANT SELECT ON profiles TO authenticated;
GRANT UPDATE ON profiles TO authenticated;
GRANT INSERT ON profiles TO authenticated;

GRANT SELECT ON wallets TO authenticated;

GRANT SELECT ON wallet_transactions TO authenticated;

GRANT SELECT ON subscriptions TO authenticated;
GRANT INSERT ON subscriptions TO authenticated;
GRANT UPDATE ON subscriptions TO authenticated;

GRANT SELECT ON products TO authenticated;
GRANT INSERT ON products TO authenticated;
GRANT UPDATE ON products TO authenticated;
GRANT DELETE ON products TO authenticated;

GRANT SELECT ON orders TO authenticated;
GRANT INSERT ON orders TO authenticated;
GRANT UPDATE ON orders TO authenticated;

-- Permissions pour service_role (complet)
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO service_role;

-- ============================================
-- COMMENTAIRES FINAUX
-- ============================================

COMMENT ON POLICY "Users can view their own escrow transactions" ON escrow_transactions 
IS 'Les utilisateurs peuvent voir uniquement les transactions escrow où ils sont impliqués (payeur ou receveur)';

COMMENT ON POLICY "Vendors can view their own products" ON products 
IS 'Les vendeurs peuvent voir tous leurs produits (actifs et inactifs)';

COMMENT ON POLICY "Anyone can view active products" ON products 
IS 'Tous les utilisateurs (même non authentifiés) peuvent voir les produits actifs';

COMMENT ON FUNCTION list_rls_policies() 
IS 'Liste toutes les politiques RLS actives dans le schéma public pour audit';

-- ============================================
-- TEST DES POLICIES (Optionnel)
-- ============================================

-- Pour tester, exécutez ces requêtes en tant qu'utilisateur authentifié:

/*
-- Test 1: Voir ses propres transactions escrow
SELECT * FROM escrow_transactions;

-- Test 2: Voir son propre profil
SELECT * FROM profiles WHERE id = auth.uid();

-- Test 3: Voir son wallet
SELECT * FROM wallets WHERE user_id = auth.uid();

-- Test 4: Voir les produits actifs
SELECT * FROM products WHERE is_active = true;

-- Test 5: Lister les policies actives
SELECT * FROM list_rls_policies();
*/
