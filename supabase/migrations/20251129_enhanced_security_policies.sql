-- ============================================
-- 🔐 POLITIQUES DE SÉCURITÉ RENFORCÉES (RLS)
-- Protection supplémentaire sans modifier les tables existantes
-- ============================================

-- ============================================
-- 1. PROTECTION DES PROFILS UTILISATEURS
-- ============================================

-- Politique : Les utilisateurs ne peuvent voir que leur propre profil (sauf admins/PDG)
CREATE POLICY IF NOT EXISTS "profiles_view_own_enhanced"
ON profiles FOR SELECT
USING (
  auth.uid() = id 
  OR 
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role IN ('admin', 'pdg')
  )
);

-- Politique : Les utilisateurs ne peuvent modifier que leur propre profil
CREATE POLICY IF NOT EXISTS "profiles_update_own_enhanced"
ON profiles FOR UPDATE
USING (auth.uid() = id)
WITH CHECK (
  auth.uid() = id 
  AND 
  -- Empêcher auto-promotion de rôle
  (
    role = (SELECT role FROM profiles WHERE id = auth.uid())
    OR
    EXISTS (
      SELECT 1 FROM profiles p 
      WHERE p.id = auth.uid() 
      AND p.role IN ('admin', 'pdg')
    )
  )
);

-- ============================================
-- 2. PROTECTION DES WALLETS (ENHANCED)
-- ============================================

-- Politique : Protection stricte de consultation des wallets
CREATE POLICY IF NOT EXISTS "wallets_strict_view"
ON wallets FOR SELECT
USING (
  auth.uid() = user_id
  AND
  -- Vérifier que le wallet n'est pas suspendu
  status = 'active'
);

-- Politique : Empêcher modification directe du balance
CREATE POLICY IF NOT EXISTS "wallets_prevent_balance_tampering"
ON wallets FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (
  -- Le balance ne peut être modifié que via RPC functions
  balance = (SELECT balance FROM wallets WHERE id = wallets.id)
  OR
  -- Sauf par les admins
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role IN ('admin', 'pdg')
  )
);

-- ============================================
-- 3. PROTECTION DES TRANSACTIONS
-- ============================================

-- Politique : Les utilisateurs ne peuvent voir que leurs propres transactions
CREATE POLICY IF NOT EXISTS "enhanced_transactions_strict_view"
ON enhanced_transactions FOR SELECT
USING (
  auth.uid() = sender_id 
  OR 
  auth.uid() = receiver_id
  OR
  -- PDG et admins peuvent voir toutes les transactions
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role IN ('admin', 'pdg')
  )
);

-- Politique : Empêcher modification des transactions après création
CREATE POLICY IF NOT EXISTS "enhanced_transactions_immutable"
ON enhanced_transactions FOR UPDATE
USING (
  -- Seuls les admins peuvent modifier les transactions
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role IN ('admin', 'pdg')
  )
)
WITH CHECK (
  -- Ne peut pas modifier le montant ou les parties
  amount = (SELECT amount FROM enhanced_transactions WHERE id = enhanced_transactions.id)
  AND
  sender_id = (SELECT sender_id FROM enhanced_transactions WHERE id = enhanced_transactions.id)
  AND
  receiver_id = (SELECT receiver_id FROM enhanced_transactions WHERE id = enhanced_transactions.id)
);

-- Politique : Empêcher suppression des transactions
CREATE POLICY IF NOT EXISTS "enhanced_transactions_prevent_delete"
ON enhanced_transactions FOR DELETE
USING (
  -- Seul le PDG peut supprimer (cas exceptionnels)
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role = 'pdg'
  )
);

-- ============================================
-- 4. PROTECTION DES PRODUITS E-COMMERCE
-- ============================================

-- Politique : Les vendeurs ne peuvent voir/modifier que leurs produits
CREATE POLICY IF NOT EXISTS "products_vendor_only_enhanced"
ON products FOR ALL
USING (
  vendor_id = auth.uid()
  OR
  -- PDG et admins peuvent tout voir
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role IN ('admin', 'pdg')
  )
);

-- Politique : Empêcher modification du vendeur sur un produit existant
CREATE POLICY IF NOT EXISTS "products_prevent_vendor_change"
ON products FOR UPDATE
USING (vendor_id = auth.uid())
WITH CHECK (
  vendor_id = (SELECT vendor_id FROM products WHERE id = products.id)
);

-- ============================================
-- 5. PROTECTION DES COMMANDES
-- ============================================

-- Politique : Les utilisateurs ne voient que leurs propres commandes
CREATE POLICY IF NOT EXISTS "orders_strict_view"
ON orders FOR SELECT
USING (
  customer_id = auth.uid()
  OR
  vendor_id = auth.uid()
  OR
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role IN ('admin', 'pdg')
  )
);

-- Politique : Empêcher modification du montant après création
CREATE POLICY IF NOT EXISTS "orders_immutable_amount"
ON orders FOR UPDATE
USING (
  customer_id = auth.uid() OR vendor_id = auth.uid()
)
WITH CHECK (
  total_amount = (SELECT total_amount FROM orders WHERE id = orders.id)
  OR
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role IN ('admin', 'pdg')
  )
);

-- ============================================
-- 6. PROTECTION DES DONNÉES SENSIBLES (KYC)
-- ============================================

-- Politique : Les données KYC ne sont visibles que par l'utilisateur et les admins
CREATE POLICY IF NOT EXISTS "kyc_documents_strict_access"
ON kyc_documents FOR SELECT
USING (
  user_id = auth.uid()
  OR
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role IN ('admin', 'pdg')
  )
);

-- Politique : Empêcher modification après validation
CREATE POLICY IF NOT EXISTS "kyc_documents_prevent_tampering"
ON kyc_documents FOR UPDATE
USING (user_id = auth.uid())
WITH CHECK (
  -- Si déjà vérifié, ne peut pas être modifié
  (
    (SELECT verification_status FROM kyc_documents WHERE id = kyc_documents.id) != 'verified'
    OR
    EXISTS (
      SELECT 1 FROM profiles p 
      WHERE p.id = auth.uid() 
      AND p.role IN ('admin', 'pdg')
    )
  )
);

-- ============================================
-- 7. PROTECTION DES MESSAGES ET COMMUNICATIONS
-- ============================================

-- Politique : Les utilisateurs ne voient que leurs conversations
CREATE POLICY IF NOT EXISTS "messages_participants_only"
ON messages FOR SELECT
USING (
  sender_id = auth.uid() 
  OR 
  receiver_id = auth.uid()
  OR
  -- Support peut voir les messages
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role IN ('admin', 'pdg', 'support')
  )
);

-- Politique : Empêcher modification des messages envoyés
CREATE POLICY IF NOT EXISTS "messages_immutable_after_send"
ON messages FOR UPDATE
USING (sender_id = auth.uid())
WITH CHECK (
  -- Peut uniquement marquer comme lu
  content = (SELECT content FROM messages WHERE id = messages.id)
  AND
  sender_id = (SELECT sender_id FROM messages WHERE id = messages.id)
  AND
  receiver_id = (SELECT receiver_id FROM messages WHERE id = messages.id)
);

-- ============================================
-- 8. PROTECTION DES LOGS D'AUDIT
-- ============================================

-- Politique : Les logs d'audit sont en lecture seule pour les admins
CREATE POLICY IF NOT EXISTS "audit_logs_readonly"
ON audit_logs FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role IN ('admin', 'pdg')
  )
);

-- Politique : Empêcher toute modification des logs
CREATE POLICY IF NOT EXISTS "audit_logs_immutable"
ON audit_logs FOR UPDATE
USING (false);

-- Politique : Empêcher toute suppression des logs
CREATE POLICY IF NOT EXISTS "audit_logs_prevent_delete"
ON audit_logs FOR DELETE
USING (false);

-- ============================================
-- 9. PROTECTION DES SUBSCRIPTIONS (DRIVERS)
-- ============================================

-- Politique : Les chauffeurs ne voient que leur propre abonnement
CREATE POLICY IF NOT EXISTS "driver_subscriptions_own_only"
ON driver_subscriptions FOR SELECT
USING (
  driver_id = auth.uid()
  OR
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role IN ('admin', 'pdg')
  )
);

-- Politique : Empêcher annulation frauduleuse d'abonnement
CREATE POLICY IF NOT EXISTS "driver_subscriptions_prevent_fraud"
ON driver_subscriptions FOR UPDATE
USING (driver_id = auth.uid())
WITH CHECK (
  -- Ne peut pas réactiver un abonnement expiré manuellement
  (
    status = 'active' 
    AND 
    expires_at > NOW()
  )
  OR
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role IN ('admin', 'pdg')
  )
);

-- ============================================
-- 10. FONCTIONS DE SÉCURITÉ UTILITAIRES
-- ============================================

-- Fonction : Vérifier si un utilisateur a un rôle spécifique
CREATE OR REPLACE FUNCTION check_user_role(required_role TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM profiles 
    WHERE id = auth.uid() 
    AND role = required_role
  );
END;
$$;

-- Fonction : Vérifier si un utilisateur est propriétaire d'une ressource
CREATE OR REPLACE FUNCTION is_resource_owner(resource_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN auth.uid() = resource_user_id;
END;
$$;

-- Fonction : Logger les tentatives d'accès non autorisées
CREATE OR REPLACE FUNCTION log_unauthorized_access()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO security_audit_logs (
    user_id,
    action,
    table_name,
    attempted_at,
    details
  ) VALUES (
    auth.uid(),
    TG_OP,
    TG_TABLE_NAME,
    NOW(),
    jsonb_build_object(
      'reason', 'Unauthorized access attempt',
      'ip', current_setting('request.headers', true)::jsonb->>'x-real-ip'
    )
  );
  
  RETURN NULL;
END;
$$;

-- ============================================
-- 11. TRIGGERS DE SÉCURITÉ
-- ============================================

-- Trigger : Empêcher modification de created_at
CREATE OR REPLACE FUNCTION prevent_created_at_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.created_at IS DISTINCT FROM NEW.created_at THEN
    RAISE EXCEPTION 'Cannot modify created_at timestamp';
  END IF;
  RETURN NEW;
END;
$$;

-- Appliquer le trigger sur toutes les tables importantes
DO $$
DECLARE
  t TEXT;
BEGIN
  FOR t IN 
    SELECT table_name 
    FROM information_schema.columns 
    WHERE column_name = 'created_at' 
    AND table_schema = 'public'
  LOOP
    EXECUTE format(
      'CREATE TRIGGER prevent_created_at_mod_%s
       BEFORE UPDATE ON %s
       FOR EACH ROW
       EXECUTE FUNCTION prevent_created_at_modification()',
      t, t
    );
  END LOOP;
END;
$$;

-- ============================================
-- 12. INDICES POUR PERFORMANCE DES RLS
-- ============================================

-- Indices pour améliorer les performances des politiques RLS
CREATE INDEX IF NOT EXISTS idx_profiles_role ON profiles(role);
CREATE INDEX IF NOT EXISTS idx_profiles_id_role ON profiles(id, role);
CREATE INDEX IF NOT EXISTS idx_wallets_user_status ON wallets(user_id, status);
CREATE INDEX IF NOT EXISTS idx_transactions_sender ON enhanced_transactions(sender_id);
CREATE INDEX IF NOT EXISTS idx_transactions_receiver ON enhanced_transactions(receiver_id);
CREATE INDEX IF NOT EXISTS idx_products_vendor ON products(vendor_id);
CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_vendor ON orders(vendor_id);
CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_receiver ON messages(receiver_id);

-- ============================================
-- COMMENTAIRES
-- ============================================

COMMENT ON POLICY "profiles_view_own_enhanced" ON profiles IS 
'Politique de sécurité renforcée : les utilisateurs ne peuvent voir que leur propre profil sauf admins/PDG';

COMMENT ON POLICY "wallets_prevent_balance_tampering" ON wallets IS 
'Empêche la modification directe du solde des wallets par les utilisateurs';

COMMENT ON POLICY "enhanced_transactions_immutable" ON enhanced_transactions IS 
'Rend les transactions immuables après création (sauf pour les admins)';

COMMENT ON FUNCTION check_user_role IS 
'Fonction utilitaire pour vérifier le rôle d\'un utilisateur de manière sécurisée';

COMMENT ON FUNCTION prevent_created_at_modification IS 
'Empêche la modification du timestamp de création pour l\'intégrité des données';
