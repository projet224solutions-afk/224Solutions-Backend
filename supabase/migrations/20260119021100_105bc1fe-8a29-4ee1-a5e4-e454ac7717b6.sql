-- Modifier la fonction calculate_agent_commission pour synchroniser agent_wallets ET wallets
CREATE OR REPLACE FUNCTION public.calculate_agent_commission(
  p_agent_id uuid, 
  p_amount numeric, 
  p_source_type text, 
  p_related_user_id uuid DEFAULT NULL::uuid, 
  p_transaction_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_agent RECORD;
  v_parent_agent RECORD;
  v_sous_agent_commission NUMERIC;
  v_principal_commission NUMERIC;
  v_result JSONB;
BEGIN
  -- Récupérer l'agent
  SELECT * INTO v_agent
  FROM agents_management
  WHERE id = p_agent_id AND is_active = true;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Agent non trouvé ou inactif';
  END IF;

  -- Calculer les commissions
  IF v_agent.type_agent = 'sous_agent' THEN
    -- Commission du sous-agent (utiliser le montant complet si commission_sous_agent est NULL ou 0)
    v_sous_agent_commission := CASE 
      WHEN v_agent.commission_sous_agent IS NULL OR v_agent.commission_sous_agent = 0 THEN p_amount
      ELSE p_amount * (v_agent.commission_sous_agent / 100)
    END;
    
    -- Créditer le wallet agent (agent_wallets)
    UPDATE agent_wallets
    SET balance = balance + v_sous_agent_commission,
        updated_at = NOW()
    WHERE agent_id = p_agent_id;
    
    -- ✅ SYNCHRONISER avec la table wallets (portefeuille utilisateur)
    IF v_agent.user_id IS NOT NULL THEN
      UPDATE wallets
      SET balance = balance + v_sous_agent_commission,
          updated_at = NOW()
      WHERE user_id = v_agent.user_id;
      
      -- Si le wallet n'existe pas, le créer
      IF NOT FOUND THEN
        INSERT INTO wallets (user_id, balance, currency, wallet_status)
        VALUES (v_agent.user_id, v_sous_agent_commission, 'GNF', 'active');
      END IF;
    END IF;
    
    -- Logger la commission du sous-agent
    INSERT INTO agent_commissions_log (
      agent_id, amount, source_type, related_user_id, transaction_id, description
    ) VALUES (
      p_agent_id, v_sous_agent_commission, p_source_type, p_related_user_id, p_transaction_id,
      'Commission création utilisateur: ' || v_sous_agent_commission || ' GNF'
    );

    -- Si le sous-agent a un parent, calculer la commission du parent
    IF v_agent.parent_agent_id IS NOT NULL THEN
      SELECT * INTO v_parent_agent
      FROM agents_management
      WHERE id = v_agent.parent_agent_id AND is_active = true;
      
      IF FOUND THEN
        v_principal_commission := CASE 
          WHEN v_parent_agent.commission_agent_principal IS NULL OR v_parent_agent.commission_agent_principal = 0 THEN 0
          ELSE p_amount * (v_parent_agent.commission_agent_principal / 100)
        END;
        
        IF v_principal_commission > 0 THEN
          -- Créditer le wallet de l'agent principal
          UPDATE agent_wallets
          SET balance = balance + v_principal_commission,
              updated_at = NOW()
          WHERE agent_id = v_parent_agent.id;
          
          -- ✅ SYNCHRONISER avec la table wallets du parent
          IF v_parent_agent.user_id IS NOT NULL THEN
            UPDATE wallets
            SET balance = balance + v_principal_commission,
                updated_at = NOW()
            WHERE user_id = v_parent_agent.user_id;
            
            IF NOT FOUND THEN
              INSERT INTO wallets (user_id, balance, currency, wallet_status)
              VALUES (v_parent_agent.user_id, v_principal_commission, 'GNF', 'active');
            END IF;
          END IF;
          
          -- Logger la commission de l'agent principal
          INSERT INTO agent_commissions_log (
            agent_id, amount, source_type, related_user_id, transaction_id, description
          ) VALUES (
            v_parent_agent.id, v_principal_commission, p_source_type, p_related_user_id, p_transaction_id,
            'Commission agent principal ' || v_parent_agent.commission_agent_principal || '%'
          );
        END IF;
      END IF;
    END IF;
    
    v_result := jsonb_build_object(
      'sous_agent_commission', v_sous_agent_commission,
      'principal_commission', COALESCE(v_principal_commission, 0),
      'total_commissions', v_sous_agent_commission + COALESCE(v_principal_commission, 0)
    );
    
  ELSE
    -- Agent principal (utiliser le montant complet si commission_agent_principal est NULL ou 0)
    v_principal_commission := CASE 
      WHEN v_agent.commission_agent_principal IS NULL OR v_agent.commission_agent_principal = 0 THEN p_amount
      ELSE p_amount * (v_agent.commission_agent_principal / 100)
    END;
    
    -- Créditer le wallet agent
    UPDATE agent_wallets
    SET balance = balance + v_principal_commission,
        updated_at = NOW()
    WHERE agent_id = p_agent_id;
    
    -- ✅ SYNCHRONISER avec la table wallets (portefeuille utilisateur)
    IF v_agent.user_id IS NOT NULL THEN
      UPDATE wallets
      SET balance = balance + v_principal_commission,
          updated_at = NOW()
      WHERE user_id = v_agent.user_id;
      
      -- Si le wallet n'existe pas, le créer
      IF NOT FOUND THEN
        INSERT INTO wallets (user_id, balance, currency, wallet_status)
        VALUES (v_agent.user_id, v_principal_commission, 'GNF', 'active');
      END IF;
    END IF;
    
    -- Logger la commission
    INSERT INTO agent_commissions_log (
      agent_id, amount, source_type, related_user_id, transaction_id, description
    ) VALUES (
      p_agent_id, v_principal_commission, p_source_type, p_related_user_id, p_transaction_id,
      'Commission création utilisateur: ' || v_principal_commission || ' GNF'
    );
    
    v_result := jsonb_build_object(
      'principal_commission', v_principal_commission,
      'total_commissions', v_principal_commission
    );
  END IF;

  RETURN v_result;
END;
$function$;

-- Synchroniser immédiatement le wallet existant de l'agent AGT0010
UPDATE wallets 
SET balance = (
  SELECT aw.balance 
  FROM agent_wallets aw 
  JOIN agents_management am ON aw.agent_id = am.id 
  WHERE am.agent_code = 'AGT0010'
)
WHERE user_id = (
  SELECT user_id 
  FROM agents_management 
  WHERE agent_code = 'AGT0010'
);

-- Vérifier les agents qui ont des commissions dans agent_wallets mais pas synchronisées dans wallets
UPDATE wallets w
SET balance = w.balance + aw.balance
FROM agent_wallets aw
JOIN agents_management am ON aw.agent_id = am.id
WHERE am.user_id = w.user_id
  AND aw.balance > 0
  AND w.balance = 0;