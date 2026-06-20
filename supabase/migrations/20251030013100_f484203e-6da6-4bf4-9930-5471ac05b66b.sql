
-- Supprimer la colonne user_id de bureaus si elle existe
ALTER TABLE bureaus DROP COLUMN IF EXISTS user_id;

-- Créer une table pour les wallets des bureaux
CREATE TABLE IF NOT EXISTS bureau_wallets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bureau_id UUID NOT NULL UNIQUE REFERENCES bureaus(id) ON DELETE CASCADE,
  balance NUMERIC NOT NULL DEFAULT 0 CHECK (balance >= 0),
  currency VARCHAR(3) NOT NULL DEFAULT 'GNF',
  wallet_status TEXT NOT NULL DEFAULT 'active' CHECK (wallet_status IN ('active', 'blocked', 'suspended')),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_bureau_wallets_bureau_id ON bureau_wallets(bureau_id);

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_bureau_wallet_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_bureau_wallet_timestamp ON bureau_wallets;
CREATE TRIGGER trigger_update_bureau_wallet_timestamp
  BEFORE UPDATE ON bureau_wallets
  FOR EACH ROW
  EXECUTE FUNCTION update_bureau_wallet_updated_at();

-- Fonction pour créer automatiquement un wallet pour un bureau
CREATE OR REPLACE FUNCTION create_bureau_wallet()
RETURNS TRIGGER AS $$
BEGIN
  -- Créer un wallet pour le nouveau bureau
  INSERT INTO bureau_wallets (bureau_id, balance, currency, wallet_status)
  VALUES (NEW.id, 0, 'GNF', 'active')
  ON CONFLICT (bureau_id) DO NOTHING;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger pour créer automatiquement un wallet lors de la création d'un bureau
DROP TRIGGER IF EXISTS trigger_create_bureau_wallet ON bureaus;
CREATE TRIGGER trigger_create_bureau_wallet
  AFTER INSERT ON bureaus
  FOR EACH ROW
  EXECUTE FUNCTION create_bureau_wallet();

-- Créer des wallets pour les bureaux existants
INSERT INTO bureau_wallets (bureau_id, balance, currency, wallet_status)
SELECT id, 0, 'GNF', 'active'
FROM bureaus
WHERE id NOT IN (SELECT bureau_id FROM bureau_wallets)
ON CONFLICT (bureau_id) DO NOTHING;

-- Policies RLS pour bureau_wallets
ALTER TABLE bureau_wallets ENABLE ROW LEVEL SECURITY;

-- Admins peuvent tout voir
CREATE POLICY "Admins can manage bureau wallets"
ON bureau_wallets
FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
);

-- Service role accès complet
CREATE POLICY "Service role full access to bureau_wallets"
ON bureau_wallets
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- Les bureaux peuvent voir leur propre wallet (via access_token)
CREATE POLICY "Bureaus can view their own wallet"
ON bureau_wallets
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM bureaus
    WHERE bureaus.id = bureau_wallets.bureau_id
    AND bureaus.access_token IS NOT NULL
  )
);
