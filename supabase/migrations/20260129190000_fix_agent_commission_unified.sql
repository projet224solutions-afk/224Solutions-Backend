-- =====================================================
-- CORRECTION UNIFIÉE DU SYSTÈME DE COMMISSION AGENT
-- 224SOLUTIONS - 29 Janvier 2026
-- =====================================================
-- Ce script unifie les deux systèmes de commission:
-- 1. agent_created_users (création directe par agent)
-- 2. user_agent_affiliations (inscription via lien d'affiliation)
-- =====================================================

-- 1. Fonction unifiée pour trouver l'agent d'un utilisateur
CREATE OR REPLACE FUNCTION public.get_user_agent(p_user_id UUID)
RETURNS TABLE (
  agent_id UUID,
  agent_name TEXT,
  agent_type TEXT,
  commission_rate NUMERIC,
  parent_agent_id UUID,
  source TEXT -- 'direct' ou 'affiliate'
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- D'abord vérifier agent_created_users (création directe)
  RETURN QUERY
  SELECT 
    am.id as agent_id,
    am.name as agent_name,
    am.type_agent as agent_type,
    COALESCE(am.commission_rate, am.commission_agent_principal, 20)::NUMERIC as commission_rate,
    am.parent_agent_id,
    'direct'::TEXT as source
  FROM agent_created_users acu
  JOIN agents_management am ON am.id = acu.agent_id
  WHERE acu.user_id = p_user_id
  AND am.is_active = true
  LIMIT 1;
  
  -- Si trouvé, retourner
  IF FOUND THEN
    RETURN;
  END IF;
  
  -- Sinon vérifier user_agent_affiliations (lien d'affiliation)
  RETURN QUERY
  SELECT 
    am.id as agent_id,
    am.name as agent_name,
    am.type_agent as agent_type,
    COALESCE(am.commission_rate, am.commission_agent_principal, 20)::NUMERIC as commission_rate,
    am.parent_agent_id,
    'affiliate'::TEXT as source
  FROM user_agent_affiliations uaa
  JOIN agents_management am ON am.id = uaa.agent_id
  WHERE uaa.user_id = p_user_id
  AND uaa.is_verified = true
  AND am.is_active = true
  LIMIT 1;
END;
$$;

-- 2. Mettre à jour credit_agent_commission pour utiliser la nouvelle fonction
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
BEGIN
  -- 1. Trouver l'agent de l'utilisateur (unifié)
  SELECT * INTO v_agent
  FROM get_user_agent(p_user_id);
  
  IF v_agent.agent_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', true,
      'has_agent', false,
      'message', 'Utilisateur non affilié à un agent'
    );
  END IF;
  
  -- 2. Récupérer les informations complètes de l'agent
  SELECT * INTO v_agent
  FROM agents_management
  WHERE id = v_agent.agent_id AND is_active = true;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Agent non trouvé ou inactif'
    );
  END IF;
  
  -- 3. Calculer la commission selon le type d'agent
  IF v_agent.type_agent = 'sous_agent' THEN
    -- Sous-agent: utiliser commission_sous_agent
    v_sub_agent_rate := COALESCE(v_agent.commission_sous_agent, 10);
    v_agent_commission := p_amount * (v_sub_agent_rate / 100);
    
    -- Créditer le wallet du sous-agent
    UPDATE agent_wallets
    SET balance = balance + v_agent_commission,
        updated_at = NOW()
    WHERE agent_id = v_agent.id;
    
    -- Si pas de wallet, le créer
    IF NOT FOUND THEN
      INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
      VALUES (v_agent.id, v_agent_commission, 'GNF', 'active');
    END IF;
    
    -- Logger la commission du sous-agent
    INSERT INTO agent_commissions_log (
      agent_id, amount, source_type, related_user_id, transaction_id, description
    ) VALUES (
      v_agent.id, 
      v_agent_commission, 
      p_source_type, 
      p_user_id, 
      p_transaction_id,
      'Commission sous-agent ' || v_sub_agent_rate || '% sur ' || p_source_type
    );
    
    -- Calculer commission de l'agent principal (parent)
    IF v_agent.parent_agent_id IS NOT NULL THEN
      SELECT * INTO v_parent_agent
      FROM agents_management
      WHERE id = v_agent.parent_agent_id AND is_active = true;
      
      IF FOUND THEN
        v_commission_rate := COALESCE(v_parent_agent.commission_agent_principal, 15);
        v_parent_commission := p_amount * (v_commission_rate / 100);
        
        -- Créditer le wallet de l'agent principal
        UPDATE agent_wallets
        SET balance = balance + v_parent_commission,
            updated_at = NOW()
        WHERE agent_id = v_parent_agent.id;
        
        IF NOT FOUND THEN
          INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
          VALUES (v_parent_agent.id, v_parent_commission, 'GNF', 'active');
        END IF;
        
        -- Logger la commission de l'agent principal
        INSERT INTO agent_commissions_log (
          agent_id, amount, source_type, related_user_id, transaction_id, description
        ) VALUES (
          v_parent_agent.id, 
          v_parent_commission, 
          p_source_type, 
          p_user_id, 
          p_transaction_id,
          'Commission agent principal ' || v_commission_rate || '% via sous-agent ' || v_agent.name
        );
      END IF;
    END IF;
    
    v_result := jsonb_build_object(
      'success', true,
      'has_agent', true,
      'agent_type', 'sous_agent',
      'agent_id', v_agent.id,
      'agent_name', v_agent.name,
      'agent_commission', v_agent_commission,
      'agent_rate', v_sub_agent_rate,
      'parent_agent_id', v_agent.parent_agent_id,
      'parent_commission', COALESCE(v_parent_commission, 0),
      'total_commissions', v_agent_commission + COALESCE(v_parent_commission, 0)
    );
    
  ELSE
    -- Agent principal: utiliser commission_rate ou commission_agent_principal
    v_commission_rate := COALESCE(v_agent.commission_rate, v_agent.commission_agent_principal, 20);
    v_agent_commission := p_amount * (v_commission_rate / 100);
    
    -- Créditer le wallet de l'agent
    UPDATE agent_wallets
    SET balance = balance + v_agent_commission,
        updated_at = NOW()
    WHERE agent_id = v_agent.id;
    
    IF NOT FOUND THEN
      INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
      VALUES (v_agent.id, v_agent_commission, 'GNF', 'active');
    END IF;
    
    -- Logger la commission
    INSERT INTO agent_commissions_log (
      agent_id, amount, source_type, related_user_id, transaction_id, description
    ) VALUES (
      v_agent.id, 
      v_agent_commission, 
      p_source_type, 
      p_user_id, 
      p_transaction_id,
      'Commission agent principal ' || v_commission_rate || '% sur ' || p_source_type
    );
    
    v_result := jsonb_build_object(
      'success', true,
      'has_agent', true,
      'agent_type', 'principal',
      'agent_id', v_agent.id,
      'agent_name', v_agent.name,
      'agent_commission', v_agent_commission,
      'agent_rate', v_commission_rate,
      'total_commissions', v_agent_commission
    );
  END IF;
  
  RETURN v_result;
END;
$$;

-- 3. Fonction pour valider et créditer les commissions en attente (CRON)
CREATE OR REPLACE FUNCTION public.process_pending_affiliate_commissions()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_commission RECORD;
  v_processed INT := 0;
  v_failed INT := 0;
BEGIN
  -- Traiter toutes les commissions dont la date de validation est passée
  FOR v_commission IN
    SELECT * FROM agent_affiliate_commissions
    WHERE status = 'pending'
    AND validation_date <= NOW()
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      -- Créditer le wallet de l'agent
      UPDATE agent_wallets
      SET balance = balance + v_commission.commission_amount,
          updated_at = NOW()
      WHERE agent_id = v_commission.agent_id;
      
      -- Si pas de wallet, le créer
      IF NOT FOUND THEN
        INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
        VALUES (v_commission.agent_id, v_commission.commission_amount, 'GNF', 'active');
      END IF;
      
      -- Marquer comme validé
      UPDATE agent_affiliate_commissions
      SET status = 'validated',
          validated_at = NOW()
      WHERE id = v_commission.id;
      
      v_processed := v_processed + 1;
      
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      -- Logger l'erreur
      RAISE WARNING 'Erreur validation commission %: %', v_commission.id, SQLERRM;
    END;
  END LOOP;
  
  RETURN jsonb_build_object(
    'success', true,
    'processed', v_processed,
    'failed', v_failed,
    'timestamp', NOW()
  );
END;
$$;

-- 4. Trigger pour créditer automatiquement le wallet quand une commission est validée manuellement
CREATE OR REPLACE FUNCTION public.on_commission_validated()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Si le statut passe de 'pending' à 'validated'
  IF OLD.status = 'pending' AND NEW.status = 'validated' THEN
    -- Créditer le wallet
    UPDATE agent_wallets
    SET balance = balance + NEW.commission_amount,
        updated_at = NOW()
    WHERE agent_id = NEW.agent_id;
    
    -- Si pas de wallet, le créer
    IF NOT FOUND THEN
      INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
      VALUES (NEW.agent_id, NEW.commission_amount, 'GNF', 'active');
    END IF;
    
    NEW.validated_at := NOW();
  END IF;
  
  RETURN NEW;
END;
$$;

-- Créer le trigger s'il n'existe pas
DROP TRIGGER IF EXISTS trigger_commission_validated ON agent_affiliate_commissions;
CREATE TRIGGER trigger_commission_validated
  BEFORE UPDATE ON agent_affiliate_commissions
  FOR EACH ROW
  EXECUTE FUNCTION on_commission_validated();

-- 5. Vue pour les statistiques de commission d'un agent
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
  (SELECT COALESCE(SUM(commission_amount), 0) FROM agent_affiliate_commissions WHERE agent_id = a.id AND status = 'pending') as pending_commissions
FROM agents_management a
LEFT JOIN agent_wallets w ON w.agent_id = a.id;

-- 6. Grant permissions
GRANT EXECUTE ON FUNCTION get_user_agent(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION credit_agent_commission(UUID, NUMERIC, TEXT, UUID, JSONB) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION process_pending_affiliate_commissions() TO service_role;
GRANT SELECT ON agent_commission_stats TO authenticated;

COMMENT ON FUNCTION get_user_agent IS 'Trouve l''agent associé à un utilisateur (création directe OU affiliation)';
COMMENT ON FUNCTION credit_agent_commission IS 'Calcule et crédite la commission à l''agent d''un utilisateur';
COMMENT ON FUNCTION process_pending_affiliate_commissions IS 'Valide et crédite les commissions en attente (à appeler via CRON)';
