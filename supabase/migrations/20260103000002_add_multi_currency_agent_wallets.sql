-- =============================================
-- WALLETS MULTI-DEVISES AGENTS - PHASE 2
-- Permettre à chaque agent d'avoir plusieurs wallets (GNF, EUR, USD, XOF)
-- =============================================

-- 1. Ajouter colonne currency_type à agent_wallets
ALTER TABLE public.agent_wallets 
ADD COLUMN IF NOT EXISTS currency_type VARCHAR(3) DEFAULT 'GNF';

-- 2. Supprimer ancienne contrainte unique sur agent_id
ALTER TABLE public.agent_wallets 
DROP CONSTRAINT IF EXISTS agent_wallets_agent_id_key;

-- 3. Ajouter nouvelle contrainte unique sur (agent_id, currency_type)
ALTER TABLE public.agent_wallets 
ADD CONSTRAINT agent_wallets_agent_currency_unique UNIQUE (agent_id, currency_type);

-- 4. Index pour performance
CREATE INDEX IF NOT EXISTS idx_agent_wallets_currency ON public.agent_wallets(currency_type);
CREATE INDEX IF NOT EXISTS idx_agent_wallets_agent_currency ON public.agent_wallets(agent_id, currency_type);

-- 5. Mettre à jour les wallets existants avec currency_type = 'GNF'
UPDATE public.agent_wallets 
SET currency_type = 'GNF' 
WHERE currency_type IS NULL;

-- 6. Fonction pour créer les wallets multi-devises d'un agent
CREATE OR REPLACE FUNCTION create_agent_multi_currency_wallets(p_agent_id UUID)
RETURNS TABLE(currency VARCHAR(3), wallet_id UUID, created BOOLEAN) AS $$
DECLARE
  v_currencies VARCHAR(3)[] := ARRAY['GNF', 'EUR', 'USD', 'XOF'];
  v_currency VARCHAR(3);
  v_wallet_id UUID;
  v_created BOOLEAN;
BEGIN
  FOREACH v_currency IN ARRAY v_currencies
  LOOP
    -- Vérifier si le wallet existe déjà
    SELECT id INTO v_wallet_id
    FROM agent_wallets
    WHERE agent_id = p_agent_id AND currency_type = v_currency;
    
    IF v_wallet_id IS NULL THEN
      -- Créer le wallet
      INSERT INTO agent_wallets (agent_id, currency_type, balance, currency)
      VALUES (p_agent_id, v_currency, 0, v_currency)
      RETURNING id INTO v_wallet_id;
      v_created := true;
    ELSE
      v_created := false;
    END IF;
    
    RETURN QUERY SELECT v_currency, v_wallet_id, v_created;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 7. Fonction pour obtenir le wallet agent dans une devise spécifique
CREATE OR REPLACE FUNCTION get_agent_wallet_by_currency(
  p_agent_id UUID,
  p_currency VARCHAR(3) DEFAULT 'GNF'
)
RETURNS TABLE(
  wallet_id UUID,
  agent_id UUID,
  balance NUMERIC,
  currency VARCHAR(3),
  currency_type VARCHAR(3)
) AS $$
BEGIN
  -- Chercher le wallet dans la devise demandée
  RETURN QUERY
  SELECT 
    aw.id,
    aw.agent_id,
    aw.balance,
    aw.currency,
    aw.currency_type
  FROM agent_wallets aw
  WHERE aw.agent_id = p_agent_id 
    AND aw.currency_type = p_currency;
  
  -- Si pas trouvé, le créer automatiquement
  IF NOT FOUND THEN
    INSERT INTO agent_wallets (agent_id, currency_type, balance, currency)
    VALUES (p_agent_id, p_currency, 0, p_currency)
    RETURNING id, agent_id, balance, currency, currency_type
    INTO wallet_id, agent_id, balance, currency, currency_type;
    
    RETURN NEXT;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 8. Fonction pour router un transfert vers le bon wallet devise
CREATE OR REPLACE FUNCTION get_agent_target_wallet_currency(
  p_agent_id UUID,
  p_sender_country VARCHAR(3),
  p_receiver_country VARCHAR(3)
)
RETURNS VARCHAR(3) AS $$
DECLARE
  v_target_currency VARCHAR(3);
BEGIN
  -- Déterminer la devise cible selon le pays destinataire
  v_target_currency := CASE p_receiver_country
    WHEN 'FR' THEN 'EUR'
    WHEN 'DE' THEN 'EUR'
    WHEN 'IT' THEN 'EUR'
    WHEN 'ES' THEN 'EUR'
    WHEN 'PT' THEN 'EUR'
    WHEN 'BE' THEN 'EUR'
    WHEN 'NL' THEN 'EUR'
    WHEN 'AT' THEN 'EUR'
    WHEN 'IE' THEN 'EUR'
    WHEN 'GR' THEN 'EUR'
    WHEN 'US' THEN 'USD'
    WHEN 'GB' THEN 'GBP'
    WHEN 'CI' THEN 'XOF'
    WHEN 'SN' THEN 'XOF'
    WHEN 'ML' THEN 'XOF'
    WHEN 'BF' THEN 'XOF'
    WHEN 'BJ' THEN 'XOF'
    WHEN 'TG' THEN 'XOF'
    WHEN 'NE' THEN 'XOF'
    ELSE 'GNF'
  END;
  
  -- Vérifier que le wallet existe, sinon le créer
  PERFORM create_agent_multi_currency_wallets(p_agent_id);
  
  RETURN v_target_currency;
END;
$$ LANGUAGE plpgsql;

-- 9. Créer les wallets multi-devises pour tous les agents existants
DO $$
DECLARE
  r RECORD;
  v_count INT := 0;
BEGIN
  FOR r IN SELECT id FROM agents_management
  LOOP
    PERFORM create_agent_multi_currency_wallets(r.id);
    v_count := v_count + 1;
  END LOOP;
  
  RAISE NOTICE 'Wallets multi-devises créés pour % agents', v_count;
END $$;

-- 10. Trigger pour créer automatiquement les wallets multi-devises lors de la création d'un agent
CREATE OR REPLACE FUNCTION trigger_create_agent_multi_currency_wallets()
RETURNS TRIGGER AS $$
BEGIN
  PERFORM create_agent_multi_currency_wallets(NEW.id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS create_multi_currency_wallets_on_agent_creation ON agents_management;
CREATE TRIGGER create_multi_currency_wallets_on_agent_creation
AFTER INSERT ON agents_management
FOR EACH ROW
EXECUTE FUNCTION trigger_create_agent_multi_currency_wallets();

-- 11. Commentaires
COMMENT ON COLUMN agent_wallets.currency_type IS 'Type de devise du wallet: GNF, EUR, USD, XOF, etc.';
COMMENT ON FUNCTION create_agent_multi_currency_wallets IS 'Créer 4 wallets (GNF, EUR, USD, XOF) pour un agent';
COMMENT ON FUNCTION get_agent_wallet_by_currency IS 'Obtenir le wallet agent dans une devise spécifique (auto-création si absent)';
COMMENT ON FUNCTION get_agent_target_wallet_currency IS 'Déterminer la devise cible selon le pays destinataire';
