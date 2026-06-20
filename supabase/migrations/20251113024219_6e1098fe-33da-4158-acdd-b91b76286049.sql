-- Correction du système de wallet des agents

-- 1. Créer les wallets manquants pour tous les agents existants
INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
SELECT 
  id,
  0,
  'GNF',
  'active'
FROM agents_management
WHERE id NOT IN (SELECT agent_id FROM agent_wallets)
ON CONFLICT DO NOTHING;

-- 2. Créer ou remplacer la fonction pour créer automatiquement un wallet lors de la création d'un agent
CREATE OR REPLACE FUNCTION public.auto_create_agent_wallet()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Créer le wallet de l'agent automatiquement
  INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
  VALUES (NEW.id, 0, 'GNF', 'active')
  ON CONFLICT (agent_id) DO NOTHING;
  
  RETURN NEW;
END;
$$;

-- 3. Créer le trigger si il n'existe pas déjà
DROP TRIGGER IF EXISTS auto_create_agent_wallet_trigger ON agents_management;
CREATE TRIGGER auto_create_agent_wallet_trigger
  AFTER INSERT ON agents_management
  FOR EACH ROW
  EXECUTE FUNCTION auto_create_agent_wallet();

-- 4. Améliorer les politiques RLS pour agent_wallets
-- Supprimer les anciennes politiques
DROP POLICY IF EXISTS "Allow read access to agent wallets" ON agent_wallets;
DROP POLICY IF EXISTS "Allow agents to update their own wallet" ON agent_wallets;

-- Créer des politiques RLS plus précises
-- Les agents peuvent voir leur propre wallet
CREATE POLICY "agents_read_own_wallet"
  ON agent_wallets
  FOR SELECT
  TO authenticated
  USING (
    agent_id IN (
      SELECT id FROM agents_management WHERE user_id = auth.uid()
    )
  );

-- Les admins peuvent voir tous les wallets
CREATE POLICY "admins_read_all_agent_wallets"
  ON agent_wallets
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

-- Les agents peuvent mettre à jour leur propre wallet (pour les transactions)
CREATE POLICY "agents_update_own_wallet"
  ON agent_wallets
  FOR UPDATE
  TO authenticated
  USING (
    agent_id IN (
      SELECT id FROM agents_management WHERE user_id = auth.uid()
    )
  );

-- Les admins peuvent mettre à jour tous les wallets
CREATE POLICY "admins_update_all_agent_wallets"
  ON agent_wallets
  FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE id = auth.uid() AND role = 'admin'
    )
  );

-- Ajouter un index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_agent_wallets_agent_id ON agent_wallets(agent_id);