-- Politique pour permettre aux admins/PDG de voir tous les wallets
CREATE POLICY "PDG can view all wallets"
ON wallets
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

-- Politique pour permettre aux admins de gérer tous les wallets
CREATE POLICY "PDG can manage all wallets"
ON wallets
FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

-- Politique pour le service role
CREATE POLICY "service_role_all_wallets"
ON wallets
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');