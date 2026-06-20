-- Fix RLS policies for agent_wallets table
-- The issue is that there are no INSERT policies, preventing wallet creation

-- Drop existing policies to recreate them properly
DROP POLICY IF EXISTS "admins_read_all_agent_wallets" ON agent_wallets;
DROP POLICY IF EXISTS "admins_update_all_agent_wallets" ON agent_wallets;
DROP POLICY IF EXISTS "agents_read_own_wallet" ON agent_wallets;
DROP POLICY IF EXISTS "agents_update_own_wallet" ON agent_wallets;

-- READ policies
CREATE POLICY "admins_read_all_agent_wallets" 
ON agent_wallets FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE profiles.id = auth.uid() 
    AND profiles.role = 'admin'
  )
);

CREATE POLICY "agents_read_own_wallet" 
ON agent_wallets FOR SELECT
USING (
  agent_id IN (
    SELECT id FROM agents_management 
    WHERE user_id = auth.uid()
  )
);

CREATE POLICY "pdg_read_agent_wallets" 
ON agent_wallets FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM agents_management am
    JOIN pdg_management pm ON am.pdg_id = pm.id
    WHERE am.id = agent_wallets.agent_id
    AND pm.user_id = auth.uid()
  )
);

-- UPDATE policies
CREATE POLICY "admins_update_all_agent_wallets" 
ON agent_wallets FOR UPDATE
USING (
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE profiles.id = auth.uid() 
    AND profiles.role = 'admin'
  )
);

CREATE POLICY "service_role_update_agent_wallets" 
ON agent_wallets FOR UPDATE
USING (auth.role() = 'service_role');

-- INSERT policies (THIS WAS MISSING!)
CREATE POLICY "service_role_insert_agent_wallets" 
ON agent_wallets FOR INSERT
WITH CHECK (auth.role() = 'service_role');

CREATE POLICY "admins_insert_agent_wallets" 
ON agent_wallets FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE profiles.id = auth.uid() 
    AND profiles.role = 'admin'
  )
);

CREATE POLICY "pdg_insert_agent_wallets" 
ON agent_wallets FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM agents_management am
    JOIN pdg_management pm ON am.pdg_id = pm.id
    WHERE am.id = agent_wallets.agent_id
    AND pm.user_id = auth.uid()
  )
);

-- Ensure the trigger exists for automatic wallet creation
CREATE OR REPLACE FUNCTION create_agent_wallet()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
  VALUES (NEW.id, 10000, 'GNF', 'active');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_create_agent_wallet ON agents_management;
CREATE TRIGGER trigger_create_agent_wallet
AFTER INSERT ON agents_management
FOR EACH ROW
EXECUTE FUNCTION create_agent_wallet();