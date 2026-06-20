-- Fix the trigger to avoid duplicate wallet creation
-- Use ON CONFLICT DO NOTHING to prevent duplicate key errors

CREATE OR REPLACE FUNCTION create_agent_wallet()
RETURNS TRIGGER AS $$
BEGIN
  -- Only create wallet if it doesn't exist
  INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
  VALUES (NEW.id, 10000, 'GNF', 'active')
  ON CONFLICT (agent_id) DO NOTHING;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Recreate the trigger
DROP TRIGGER IF EXISTS trigger_create_agent_wallet ON agents_management;
CREATE TRIGGER trigger_create_agent_wallet
AFTER INSERT ON agents_management
FOR EACH ROW
EXECUTE FUNCTION create_agent_wallet();