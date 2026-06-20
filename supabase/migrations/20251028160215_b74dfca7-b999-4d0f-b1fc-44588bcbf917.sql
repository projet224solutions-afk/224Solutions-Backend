-- Supprimer les anciennes politiques
DROP POLICY IF EXISTS "PDG can view all wallets" ON wallets;
DROP POLICY IF EXISTS "PDG can manage all wallets" ON wallets;

-- Créer une politique simple qui utilise directement has_role (qui existe déjà)
CREATE POLICY "PDG can view all wallets"
ON wallets
FOR SELECT
USING (has_role(auth.uid(), 'admin'::user_role));

CREATE POLICY "PDG can manage all wallets"
ON wallets
FOR ALL
USING (has_role(auth.uid(), 'admin'::user_role))
WITH CHECK (has_role(auth.uid(), 'admin'::user_role));