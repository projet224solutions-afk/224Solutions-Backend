-- ============================================================
-- MIGRATION: Commission System Final Hardening
-- Fixes: anti-doublon logic bug, view unification, deprecation
-- ============================================================

-- 1. FIX credit_agent_commission: anti-doublon was checking globally
--    instead of per-agent, which blocked parent agent commissions
--    when sub-agent commission was already logged for same transaction_id.
--    Now checks per (agent_id) so both sub-agent AND parent can get their share.

CREATE OR REPLACE FUNCTION public.credit_agent_commission(
  p_user_id uuid,
  p_amount numeric,
  p_source_type text,
  p_transaction_id uuid DEFAULT NULL::uuid,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
  -- 1. Trouver l'agent de l'utilisateur
  SELECT * INTO v_agent FROM get_user_agent(p_user_id);
  
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
    RETURN jsonb_build_object('success', false, 'error', 'Agent non trouvé ou inactif');
  END IF;

  -- Anti-doublon PER AGENT: vérifier si CET agent a déjà reçu une commission pour cette transaction
  -- Important: on vérifie par agent_id car sub-agent et parent ont chacun droit à leur commission
  IF p_transaction_id IS NOT NULL THEN
    SELECT COUNT(*) INTO v_existing_count
    FROM agent_commissions_log
    WHERE agent_id = v_agent.id AND transaction_id = p_transaction_id;
    
    IF v_existing_count > 0 THEN
      RETURN jsonb_build_object(
        'success', true,
        'has_agent', true,
        'already_processed', true,
        'agent_id', v_agent.id,
        'message', 'Commission déjà créditée pour cet agent et cette transaction'
      );
    END IF;
  END IF;
  
  -- 3. Calculer la commission selon le type d'agent
  IF v_agent.type_agent = 'sous_agent' THEN
    v_sub_agent_rate := COALESCE(v_agent.commission_sous_agent, 10);
    v_agent_commission := p_amount * (v_sub_agent_rate / 100);
    
    -- Créditer le wallet du sous-agent
    UPDATE agent_wallets SET balance = balance + v_agent_commission, updated_at = NOW()
    WHERE agent_id = v_agent.id;
    IF NOT FOUND THEN
      INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
      VALUES (v_agent.id, v_agent_commission, 'GNF', 'active');
    END IF;
    
    -- Log commission sous-agent (protégé par idx_agent_commissions_log_unique_transaction)
    INSERT INTO agent_commissions_log (
      agent_id, amount, source_type, related_user_id, transaction_id, description,
      status, commission_rate, transaction_amount, currency
    ) VALUES (
      v_agent.id, v_agent_commission, p_source_type, p_user_id, p_transaction_id,
      'Commission sous-agent ' || v_sub_agent_rate || '% sur ' || p_source_type,
      'validated', v_sub_agent_rate, p_amount, COALESCE(p_metadata->>'currency', 'GNF')
    );
    
    -- Commission du parent (si existe)
    IF v_agent.parent_agent_id IS NOT NULL THEN
      SELECT * INTO v_parent_agent FROM agents_management
      WHERE id = v_agent.parent_agent_id AND is_active = true;
      
      IF FOUND THEN
        -- Anti-doublon pour le parent aussi
        IF p_transaction_id IS NOT NULL THEN
          SELECT COUNT(*) INTO v_existing_count
          FROM agent_commissions_log
          WHERE agent_id = v_parent_agent.id AND transaction_id = p_transaction_id;
          
          IF v_existing_count > 0 THEN
            -- Parent déjà crédité, on continue sans re-créditer
            v_parent_commission := 0;
          ELSE
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
        ELSE
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
    -- Agent principal direct
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
$function$;

-- 2. RECREATE agent_commission_stats view
--    Source of truth: agent_commissions_log ONLY
--    NO reference to agent_affiliate_commissions
DROP VIEW IF EXISTS public.agent_commission_stats;
CREATE VIEW public.agent_commission_stats AS
SELECT 
  a.id AS agent_id,
  a.name AS agent_name,
  a.agent_code,
  COALESCE(w.balance, 0::numeric) AS wallet_balance,
  (SELECT count(*) FROM agent_created_users WHERE agent_created_users.agent_id = a.id) AS direct_users,
  (SELECT count(*) FROM user_agent_affiliations WHERE user_agent_affiliations.agent_id = a.id AND user_agent_affiliations.is_verified = true) AS affiliated_users,
  (SELECT COALESCE(sum(cl.amount), 0::numeric) FROM agent_commissions_log cl WHERE cl.agent_id = a.id) AS total_commissions_earned,
  (SELECT COALESCE(sum(cl.amount), 0::numeric) FROM agent_commissions_log cl WHERE cl.agent_id = a.id AND cl.created_at >= date_trunc('month', now())) AS commissions_this_month,
  (SELECT COALESCE(sum(cl.amount), 0::numeric) FROM agent_commissions_log cl WHERE cl.agent_id = a.id AND cl.status = 'pending') AS pending_commissions
FROM agents_management a
LEFT JOIN agent_wallets w ON w.agent_id = a.id;

-- 3. Add comment to deprecate agent_affiliate_commissions
COMMENT ON TABLE public.agent_affiliate_commissions IS 
  'DEPRECATED - Table historique uniquement. NE PAS utiliser pour les stats officielles. '
  'Source de vérité officielle: agent_commissions_log. '
  'Cette table est conservée pour compatibilité historique mais ne doit plus être lue par les dashboards.';