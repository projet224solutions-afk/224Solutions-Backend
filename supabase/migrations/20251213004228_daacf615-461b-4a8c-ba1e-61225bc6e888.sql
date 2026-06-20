
-- ================================================================
-- CORRECTION EN PROFONDEUR DU SYSTÈME DE TRANSFERT AGENT
-- ================================================================

-- 1. SUPPRIMER TOUTES LES VERSIONS DE LA FONCTION POUR REPARTIR PROPREMENT
DROP FUNCTION IF EXISTS process_secure_wallet_transfer(UUID, UUID, NUMERIC, TEXT, TEXT);
DROP FUNCTION IF EXISTS process_secure_wallet_transfer(UUID, UUID, NUMERIC, TEXT, NUMERIC);

-- 2. CRÉER UNE FONCTION UNIFIÉE QUI GÈRE TOUS LES TYPES DE WALLETS
CREATE OR REPLACE FUNCTION process_secure_wallet_transfer(
  p_sender_id UUID,           -- user_id pour users/agents OU bureau_id pour bureaux
  p_receiver_id UUID,         -- user_id pour users/agents OU bureau_id pour bureaux  
  p_amount NUMERIC,
  p_description TEXT DEFAULT NULL,
  p_sender_type TEXT DEFAULT 'user',     -- 'user', 'agent', 'bureau'
  p_receiver_type TEXT DEFAULT 'user'    -- 'user', 'agent', 'bureau'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sender_wallet_id UUID;
  v_receiver_wallet_id UUID;
  v_sender_balance NUMERIC;
  v_receiver_balance NUMERIC;
  v_fee_rate NUMERIC := 0.01;  -- 1% de frais
  v_fee_amount NUMERIC;
  v_net_amount NUMERIC;
  v_sender_balance_after NUMERIC;
  v_receiver_balance_after NUMERIC;
  v_transaction_id TEXT;
  v_sender_user_id UUID;
  v_receiver_user_id UUID;
BEGIN
  -- Générer un ID de transaction unique
  v_transaction_id := 'TXN-' || to_char(now(), 'YYYYMMDD-HH24MISS-') || substr(gen_random_uuid()::text, 1, 8);

  -- ============================================
  -- RÉSOLUTION DU WALLET EXPÉDITEUR
  -- ============================================
  IF p_sender_type = 'bureau' THEN
    -- Expéditeur est un bureau
    SELECT id, balance INTO v_sender_wallet_id, v_sender_balance
    FROM bureau_wallets 
    WHERE bureau_id = p_sender_id AND wallet_status = 'active';
    
    v_sender_user_id := NULL; -- Les bureaux n'ont pas de user_id
  ELSIF p_sender_type = 'agent' THEN
    -- Expéditeur est un agent - chercher via agents_management
    SELECT am.user_id INTO v_sender_user_id
    FROM agents_management am
    WHERE am.id = p_sender_id;
    
    IF v_sender_user_id IS NULL THEN
      -- Peut-être que p_sender_id EST déjà le user_id
      v_sender_user_id := p_sender_id;
    END IF;
    
    SELECT id, balance INTO v_sender_wallet_id, v_sender_balance
    FROM wallets 
    WHERE user_id = v_sender_user_id AND status = 'active';
  ELSE
    -- Expéditeur est un user standard
    v_sender_user_id := p_sender_id;
    SELECT id, balance INTO v_sender_wallet_id, v_sender_balance
    FROM wallets 
    WHERE user_id = p_sender_id AND status = 'active';
  END IF;

  IF v_sender_wallet_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Wallet expéditeur non trouvé ou inactif'
    );
  END IF;

  -- ============================================
  -- RÉSOLUTION DU WALLET DESTINATAIRE
  -- ============================================
  IF p_receiver_type = 'bureau' THEN
    -- Destinataire est un bureau
    SELECT id, balance INTO v_receiver_wallet_id, v_receiver_balance
    FROM bureau_wallets 
    WHERE bureau_id = p_receiver_id AND wallet_status = 'active';
    
    v_receiver_user_id := NULL;
  ELSIF p_receiver_type = 'agent' THEN
    -- Destinataire est un agent
    SELECT am.user_id INTO v_receiver_user_id
    FROM agents_management am
    WHERE am.id = p_receiver_id;
    
    IF v_receiver_user_id IS NULL THEN
      v_receiver_user_id := p_receiver_id;
    END IF;
    
    SELECT id, balance INTO v_receiver_wallet_id, v_receiver_balance
    FROM wallets 
    WHERE user_id = v_receiver_user_id AND status = 'active';
    
    -- Créer le wallet si inexistant
    IF v_receiver_wallet_id IS NULL THEN
      INSERT INTO wallets (user_id, balance, currency, status)
      VALUES (v_receiver_user_id, 0, 'GNF', 'active')
      RETURNING id, balance INTO v_receiver_wallet_id, v_receiver_balance;
    END IF;
  ELSE
    -- Destinataire est un user standard
    v_receiver_user_id := p_receiver_id;
    SELECT id, balance INTO v_receiver_wallet_id, v_receiver_balance
    FROM wallets 
    WHERE user_id = p_receiver_id AND status = 'active';
    
    -- Créer le wallet si inexistant
    IF v_receiver_wallet_id IS NULL THEN
      INSERT INTO wallets (user_id, balance, currency, status)
      VALUES (p_receiver_id, 0, 'GNF', 'active')
      RETURNING id, balance INTO v_receiver_wallet_id, v_receiver_balance;
    END IF;
  END IF;

  IF v_receiver_wallet_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Wallet destinataire non trouvé ou inactif'
    );
  END IF;

  -- ============================================
  -- CALCUL DES MONTANTS
  -- ============================================
  v_fee_amount := ROUND(p_amount * v_fee_rate, 0);
  v_net_amount := p_amount - v_fee_amount;

  -- Vérifier le solde
  IF v_sender_balance < p_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', format('Solde insuffisant. Disponible: %s, Requis: %s', v_sender_balance, p_amount)
    );
  END IF;

  -- Calculer les nouveaux soldes
  v_sender_balance_after := v_sender_balance - p_amount;
  v_receiver_balance_after := v_receiver_balance + v_net_amount;

  -- ============================================
  -- MISE À JOUR DES WALLETS
  -- ============================================
  
  -- Débiter l'expéditeur
  IF p_sender_type = 'bureau' THEN
    UPDATE bureau_wallets 
    SET balance = v_sender_balance_after, updated_at = now()
    WHERE id = v_sender_wallet_id;
  ELSE
    UPDATE wallets 
    SET balance = v_sender_balance_after, updated_at = now()
    WHERE id = v_sender_wallet_id;
    
    -- Synchroniser agent_wallets si c'est un agent
    UPDATE agent_wallets 
    SET balance = v_sender_balance_after, updated_at = now()
    WHERE agent_id IN (SELECT id FROM agents_management WHERE user_id = v_sender_user_id);
  END IF;

  -- Créditer le destinataire  
  IF p_receiver_type = 'bureau' THEN
    UPDATE bureau_wallets 
    SET balance = v_receiver_balance_after, updated_at = now()
    WHERE id = v_receiver_wallet_id;
  ELSE
    UPDATE wallets 
    SET balance = v_receiver_balance_after, updated_at = now()
    WHERE id = v_receiver_wallet_id;
    
    -- Synchroniser agent_wallets si c'est un agent
    UPDATE agent_wallets 
    SET balance = v_receiver_balance_after, updated_at = now()
    WHERE agent_id IN (SELECT id FROM agents_management WHERE user_id = v_receiver_user_id);
  END IF;

  -- ============================================
  -- ENREGISTRER LA TRANSACTION (débit expéditeur)
  -- ============================================
  INSERT INTO wallet_transactions (
    transaction_id,
    sender_wallet_id,
    receiver_wallet_id,
    amount,
    fee,
    net_amount,
    currency,
    transaction_type,
    status,
    description,
    metadata,
    created_at,
    completed_at
  ) VALUES (
    v_transaction_id,
    v_sender_wallet_id,
    v_receiver_wallet_id,
    p_amount,
    v_fee_amount,
    v_net_amount,
    'GNF',
    'transfer',
    'completed',
    COALESCE(p_description, 'Transfert'),
    jsonb_build_object(
      'sender_type', p_sender_type,
      'receiver_type', p_receiver_type,
      'sender_id', p_sender_id,
      'receiver_id', p_receiver_id,
      'sender_balance_before', v_sender_balance,
      'sender_balance_after', v_sender_balance_after,
      'receiver_balance_before', v_receiver_balance,
      'receiver_balance_after', v_receiver_balance_after
    ),
    now(),
    now()
  );

  -- ============================================
  -- RETOURNER LE RÉSULTAT
  -- ============================================
  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'amount', p_amount,
    'fee', v_fee_amount,
    'net_amount', v_net_amount,
    'sender_balance_after', v_sender_balance_after,
    'receiver_balance_after', v_receiver_balance_after
  );
  
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM
  );
END;
$$;

-- 3. DONNER LES PERMISSIONS
GRANT EXECUTE ON FUNCTION process_secure_wallet_transfer(UUID, UUID, NUMERIC, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION process_secure_wallet_transfer(UUID, UUID, NUMERIC, TEXT, TEXT, TEXT) TO anon;

COMMENT ON FUNCTION process_secure_wallet_transfer IS 'Transfert sécurisé entre tous types de wallets (user, agent, bureau) avec frais de 1%';
