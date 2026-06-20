
-- =====================================================
-- UNIFICATION DÉFINITIVE DU SYSTÈME DE COMMISSION
-- 224SOLUTIONS
-- =====================================================

-- 1. Ajouter un index unique sur transaction_id pour empêcher les doublons
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_commissions_log_unique_transaction
ON agent_commissions_log (agent_id, transaction_id)
WHERE transaction_id IS NOT NULL;

-- 2. Ajouter colonnes enrichies à agent_commissions_log si manquantes
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'agent_commissions_log' AND column_name = 'status'
  ) THEN
    ALTER TABLE agent_commissions_log ADD COLUMN status TEXT DEFAULT 'validated';
  END IF;
  
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'agent_commissions_log' AND column_name = 'commission_rate'
  ) THEN
    ALTER TABLE agent_commissions_log ADD COLUMN commission_rate NUMERIC DEFAULT 0;
  END IF;
  
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'agent_commissions_log' AND column_name = 'transaction_amount'
  ) THEN
    ALTER TABLE agent_commissions_log ADD COLUMN transaction_amount NUMERIC DEFAULT 0;
  END IF;
  
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'agent_commissions_log' AND column_name = 'currency'
  ) THEN
    ALTER TABLE agent_commissions_log ADD COLUMN currency TEXT DEFAULT 'GNF';
  END IF;
END $$;

-- 3. Mettre à jour credit_agent_commission avec anti-doublon et champs enrichis
CREATE OR REPLACE FUNCTION public.credit_agent_commission(
  p_user_id UUID,
  p_amount NUMERIC,
  p_source_type TEXT,
  p_transaction_id UUID DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'::JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_agent RECORD;
  v_parent_agent RECORD;
  v_commission_rate NUMERIC;
  v_sub_agent_rate NUMERIC;
  v_agent_commission NUMERIC;
  v_parent_commission NUMERIC;
  v_result JSONB;
  v_existing_count INT;
BEGIN
  -- Anti-doublon: vérifier si cette transaction a déjà généré une commission
  IF p_transaction_id IS NOT NULL THEN
    SELECT COUNT(*) INTO v_existing_count
    FROM agent_commissions_log
    WHERE transaction_id = p_transaction_id;
    
    IF v_existing_count > 0 THEN
      RETURN jsonb_build_object(
        'success', true,
        'has_agent', true,
        'already_processed', true,
        'message', 'Commission déjà créditée pour cette transaction'
      );
    END IF;
  END IF;

  -- 1. Trouver l agent de l utilisateur (unifié)
  SELECT * INTO v_agent FROM get_user_agent(p_user_id);
  
  IF v_agent.agent_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'has_agent', false,
      'message', 'Utilisateur non affilié à un agent'
    );
  END IF;
  
  -- 2. Récupérer les informations complètes de l agent
  SELECT * INTO v_agent
  FROM agents_management
  WHERE id = v_agent.agent_id AND is_active = true;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent non trouvé ou inactif');
  END IF;
  
  -- 3. Calculer la commission selon le type d agent
  IF v_agent.type_agent = 'sous_agent' THEN
    v_sub_agent_rate := COALESCE(v_agent.commission_sous_agent, 10);
    v_agent_commission := p_amount * (v_sub_agent_rate / 100);
    
    UPDATE agent_wallets SET balance = balance + v_agent_commission, updated_at = NOW()
    WHERE agent_id = v_agent.id;
    IF NOT FOUND THEN
      INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
      VALUES (v_agent.id, v_agent_commission, 'GNF', 'active');
    END IF;
    
    INSERT INTO agent_commissions_log (
      agent_id, amount, source_type, related_user_id, transaction_id, description,
      status, commission_rate, transaction_amount, currency
    ) VALUES (
      v_agent.id, v_agent_commission, p_source_type, p_user_id, p_transaction_id,
      'Commission sous-agent ' || v_sub_agent_rate || '% sur ' || p_source_type,
      'validated', v_sub_agent_rate, p_amount, COALESCE(p_metadata->>'currency', 'GNF')
    );
    
    IF v_agent.parent_agent_id IS NOT NULL THEN
      SELECT * INTO v_parent_agent FROM agents_management
      WHERE id = v_agent.parent_agent_id AND is_active = true;
      
      IF FOUND THEN
        v_commission_rate := COALESCE(v_parent_agent.commission_agent_principal, 15);
        v_parent_commission := p_amount * (v_commission_rate / 100);
        
        UPDATE agent_wallets SET balance = balance + v_parent_commission, updated_at = NOW()
        WHERE agent_id = v_parent_agent.id;
        IF NOT FOUND THEN
          INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
          VALUES (v_parent_agent.id, v_parent_commission, 'GNF', 'active');
        END IF;
        
        INSERT INTO agent_commissions_log (
          agent_id, amount, source_type, related_user_id, transaction_id, description,
          status, commission_rate, transaction_amount, currency
        ) VALUES (
          v_parent_agent.id, v_parent_commission, p_source_type, p_user_id, p_transaction_id,
          'Commission agent principal ' || v_commission_rate || '% via sous-agent ' || v_agent.name,
          'validated', v_commission_rate, p_amount, COALESCE(p_metadata->>'currency', 'GNF')
        );
      END IF;
    END IF;
    
    v_result := jsonb_build_object(
      'success', true, 'has_agent', true, 'already_processed', false,
      'agent_type', 'sous_agent', 'agent_id', v_agent.id, 'agent_name', v_agent.name,
      'agent_commission', v_agent_commission, 'agent_rate', v_sub_agent_rate,
      'parent_agent_id', v_agent.parent_agent_id,
      'parent_commission', COALESCE(v_parent_commission, 0),
      'total_commissions', v_agent_commission + COALESCE(v_parent_commission, 0)
    );
  ELSE
    v_commission_rate := COALESCE(v_agent.commission_rate, v_agent.commission_agent_principal, 20);
    v_agent_commission := p_amount * (v_commission_rate / 100);
    
    UPDATE agent_wallets SET balance = balance + v_agent_commission, updated_at = NOW()
    WHERE agent_id = v_agent.id;
    IF NOT FOUND THEN
      INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
      VALUES (v_agent.id, v_agent_commission, 'GNF', 'active');
    END IF;
    
    INSERT INTO agent_commissions_log (
      agent_id, amount, source_type, related_user_id, transaction_id, description,
      status, commission_rate, transaction_amount, currency
    ) VALUES (
      v_agent.id, v_agent_commission, p_source_type, p_user_id, p_transaction_id,
      'Commission agent principal ' || v_commission_rate || '% sur ' || p_source_type,
      'validated', v_commission_rate, p_amount, COALESCE(p_metadata->>'currency', 'GNF')
    );
    
    v_result := jsonb_build_object(
      'success', true, 'has_agent', true, 'already_processed', false,
      'agent_type', 'principal', 'agent_id', v_agent.id, 'agent_name', v_agent.name,
      'agent_commission', v_agent_commission, 'agent_rate', v_commission_rate,
      'total_commissions', v_agent_commission
    );
  END IF;
  
  RETURN v_result;
END;
$$;

-- 4. Vue unifiée - n utilise QUE agent_commissions_log
CREATE OR REPLACE VIEW agent_commission_stats AS
SELECT 
  a.id as agent_id,
  a.name as agent_name,
  a.agent_code,
  COALESCE(w.balance, 0) as wallet_balance,
  (SELECT COUNT(*) FROM agent_created_users WHERE agent_id = a.id) as direct_users,
  (SELECT COUNT(*) FROM user_agent_affiliations WHERE agent_id = a.id AND is_verified = true) as affiliated_users,
  (SELECT COALESCE(SUM(amount), 0) FROM agent_commissions_log WHERE agent_id = a.id) as total_commissions_earned,
  (SELECT COALESCE(SUM(amount), 0) FROM agent_commissions_log WHERE agent_id = a.id AND created_at >= date_trunc('month', NOW())) as commissions_this_month,
  (SELECT COALESCE(SUM(amount), 0) FROM agent_commissions_log WHERE agent_id = a.id AND status = 'pending') as pending_commissions
FROM agents_management a
LEFT JOIN agent_wallets w ON w.agent_id = a.id;

GRANT EXECUTE ON FUNCTION credit_agent_commission(UUID, NUMERIC, TEXT, UUID, JSONB) TO authenticated, service_role;
GRANT SELECT ON agent_commission_stats TO authenticated;
