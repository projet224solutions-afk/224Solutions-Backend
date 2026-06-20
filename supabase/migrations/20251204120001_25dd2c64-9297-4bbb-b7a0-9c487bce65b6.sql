-- Corriger le solde du bureau BST0002 (devrait avoir 10000 + 5000 + 15000 = 30000)
UPDATE bureau_wallets 
SET balance = 30000, updated_at = now() 
WHERE id = 'c2cd89ae-fbda-4241-a69c-873cb5b2b0d3';

-- Insérer les transactions manquantes dans bureau_transactions
INSERT INTO bureau_transactions (bureau_id, type, amount, date, description, status)
VALUES 
  ('c05efee7-3962-40c7-8c09-cf8eece95a98', 'credit', 5000, '2025-12-04 11:53:27.81', 'Transfert reçu - Facture', 'completed'),
  ('c05efee7-3962-40c7-8c09-cf8eece95a98', 'credit', 15000, '2025-12-04 11:56:23.547', 'Transfert reçu - Facture', 'completed')
ON CONFLICT DO NOTHING;

-- Créer une politique RLS pour permettre les updates sur bureau_wallets
DROP POLICY IF EXISTS "Allow authenticated users to update bureau_wallets" ON bureau_wallets;
CREATE POLICY "Allow authenticated users to update bureau_wallets" 
ON bureau_wallets FOR UPDATE 
TO authenticated 
USING (true) 
WITH CHECK (true);

-- Créer une politique RLS pour permettre les inserts sur bureau_transactions
DROP POLICY IF EXISTS "Allow authenticated users to insert bureau_transactions" ON bureau_transactions;
CREATE POLICY "Allow authenticated users to insert bureau_transactions" 
ON bureau_transactions FOR INSERT 
TO authenticated 
WITH CHECK (true);