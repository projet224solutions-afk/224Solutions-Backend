-- Politique RLS pour permettre au PDG de voir tous les devis
CREATE POLICY "PDG can view all quotes"
ON quotes
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

-- Politique RLS pour permettre au PDG de voir toutes les factures
CREATE POLICY "PDG can view all invoices"
ON invoices
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);