-- Fonction pour créer un wallet agent (contourne RLS)
-- Cette fonction s'exécute avec SECURITY DEFINER pour contourner les politiques RLS

CREATE OR REPLACE FUNCTION create_agent_wallet(p_agent_id UUID)
RETURNS TABLE (
  id UUID,
  agent_id UUID,
  balance NUMERIC,
  currency TEXT,
  wallet_status TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  -- Vérifier si le wallet existe déjà
  IF EXISTS (SELECT 1 FROM agent_wallets WHERE agent_wallets.agent_id = p_agent_id) THEN
    -- Retourner le wallet existant
    RETURN QUERY
    SELECT 
      agent_wallets.id,
      agent_wallets.agent_id,
      agent_wallets.balance,
      agent_wallets.currency,
      agent_wallets.wallet_status,
      agent_wallets.created_at,
      agent_wallets.updated_at
    FROM agent_wallets
    WHERE agent_wallets.agent_id = p_agent_id;
  ELSE
    -- Créer un nouveau wallet
    RETURN QUERY
    INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
    VALUES (p_agent_id, 0, 'GNF', 'active')
    RETURNING 
      agent_wallets.id,
      agent_wallets.agent_id,
      agent_wallets.balance,
      agent_wallets.currency,
      agent_wallets.wallet_status,
      agent_wallets.created_at,
      agent_wallets.updated_at;
  END IF;
END;
$$;

-- Donner les permissions d'exécution à tous les utilisateurs authentifiés
GRANT EXECUTE ON FUNCTION create_agent_wallet(UUID) TO authenticated;

COMMENT ON FUNCTION create_agent_wallet IS 'Crée ou retourne un wallet agent existant - Contourne RLS';
