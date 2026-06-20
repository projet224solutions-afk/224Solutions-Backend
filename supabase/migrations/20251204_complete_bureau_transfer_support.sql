-- Fonction complète pour trouver le wallet d'un utilisateur ou bureau
-- Supporte: wallets (users), agent_wallets, bureau_wallets, vendor wallets

CREATE OR REPLACE FUNCTION find_wallet_by_code(
  p_code TEXT,
  p_currency VARCHAR DEFAULT 'GNF'
)
RETURNS TABLE (
  wallet_id UUID,
  wallet_type TEXT,
  owner_id UUID,
  balance NUMERIC,
  wallet_status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
  v_bureau_id UUID;
  v_agent_id UUID;
BEGIN
  -- 1. Vérifier si c'est un bureau syndicat (BST****)
  IF p_code LIKE 'BST%' THEN
    SELECT b.id, b.user_id INTO v_bureau_id, v_user_id
    FROM bureau_syndicats b
    WHERE b.bureau_code = UPPER(p_code)
    LIMIT 1;
    
    IF v_bureau_id IS NOT NULL THEN
      -- Retourner le wallet bureau
      RETURN QUERY
      SELECT 
        bw.id,
        'bureau'::TEXT,
        bw.bureau_id,
        bw.balance,
        bw.wallet_status
      FROM bureau_wallets bw
      WHERE bw.bureau_id = v_bureau_id
        AND bw.currency = p_currency
      LIMIT 1;
      RETURN;
    END IF;
  END IF;
  
  -- 2. Vérifier si c'est un agent (AGT****)
  IF p_code LIKE 'AGT%' THEN
    SELECT a.id INTO v_agent_id
    FROM agents_management a
    WHERE a.agent_code = UPPER(p_code)
    LIMIT 1;
    
    IF v_agent_id IS NOT NULL THEN
      -- Retourner le wallet agent
      RETURN QUERY
      SELECT 
        aw.id,
        'agent'::TEXT,
        aw.agent_id,
        aw.balance,
        aw.wallet_status
      FROM agent_wallets aw
      WHERE aw.agent_id = v_agent_id
        AND aw.currency = p_currency
      LIMIT 1;
      RETURN;
    END IF;
  END IF;
  
  -- 3. Chercher dans user_ids / profiles pour autres types
  SELECT user_id INTO v_user_id
  FROM user_ids
  WHERE custom_id = UPPER(p_code)
  LIMIT 1;
  
  IF v_user_id IS NULL THEN
    SELECT id INTO v_user_id
    FROM profiles
    WHERE custom_id = UPPER(p_code) OR public_id = UPPER(p_code)
    LIMIT 1;
  END IF;
  
  -- 4. Retourner le wallet standard si trouvé
  IF v_user_id IS NOT NULL THEN
    RETURN QUERY
    SELECT 
      w.id,
      'user'::TEXT,
      w.user_id,
      w.balance,
      w.wallet_status
    FROM wallets w
    WHERE w.user_id = v_user_id
      AND w.currency = p_currency
    LIMIT 1;
    RETURN;
  END IF;
  
  -- Rien trouvé
  RETURN;
END;
$$;

COMMENT ON FUNCTION find_wallet_by_code(TEXT, VARCHAR) IS 'Trouve un wallet par code utilisateur (BST, AGT, USR, VND, etc.). Retourne le wallet correspondant avec son type.';

-- Fonction preview_transfer améliorée pour supporter les bureaux
CREATE OR REPLACE FUNCTION preview_wallet_transfer_by_code(
  p_sender_code TEXT,
  p_receiver_code TEXT,
  p_amount NUMERIC,
  p_currency VARCHAR DEFAULT 'GNF'
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_sender_wallet RECORD;
  v_receiver_wallet RECORD;
  v_sender_info JSONB;
  v_receiver_info JSONB;
  v_fee_percent NUMERIC;
  v_fee_amount NUMERIC;
  v_total_debit NUMERIC;
BEGIN
  -- Trouver le wallet expéditeur
  SELECT * INTO v_sender_wallet
  FROM find_wallet_by_code(p_sender_code, p_currency);
  
  IF v_sender_wallet.wallet_id IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Expéditeur introuvable: ' || p_sender_code
    );
  END IF;
  
  -- Trouver le wallet destinataire
  SELECT * INTO v_receiver_wallet
  FROM find_wallet_by_code(p_receiver_code, p_currency);
  
  IF v_receiver_wallet.wallet_id IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Destinataire introuvable: ' || p_receiver_code
    );
  END IF;
  
  -- Vérifier que ce ne sont pas les mêmes wallets
  IF v_sender_wallet.wallet_id = v_receiver_wallet.wallet_id THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Impossible de transférer vers votre propre compte'
    );
  END IF;
  
  -- Récupérer les infos de l'expéditeur selon le type
  IF v_sender_wallet.wallet_type = 'bureau' THEN
    SELECT jsonb_build_object(
      'id', b.id,
      'name', b.bureau_code || ' - ' || b.prefecture,
      'email', COALESCE(b.president_email, 'N/A'),
      'phone', COALESCE(b.president_phone, 'N/A'),
      'custom_id', b.bureau_code,
      'type', 'bureau'
    ) INTO v_sender_info
    FROM bureau_syndicats b
    WHERE b.id = v_sender_wallet.owner_id;
  ELSIF v_sender_wallet.wallet_type = 'agent' THEN
    SELECT jsonb_build_object(
      'id', a.id,
      'name', a.name,
      'email', COALESCE(a.email, 'N/A'),
      'phone', COALESCE(a.phone, 'N/A'),
      'custom_id', a.agent_code,
      'type', 'agent'
    ) INTO v_sender_info
    FROM agents_management a
    WHERE a.id = v_sender_wallet.owner_id;
  ELSE
    SELECT jsonb_build_object(
      'id', p.id,
      'name', COALESCE(p.first_name || ' ' || p.last_name, 'Non renseigné'),
      'email', COALESCE(p.email, 'N/A'),
      'phone', COALESCE(p.phone, 'N/A'),
      'custom_id', COALESCE(p.custom_id, p.public_id),
      'type', 'user'
    ) INTO v_sender_info
    FROM profiles p
    WHERE p.id = v_sender_wallet.owner_id;
  END IF;
  
  -- Récupérer les infos du destinataire selon le type
  IF v_receiver_wallet.wallet_type = 'bureau' THEN
    SELECT jsonb_build_object(
      'id', b.id,
      'name', b.bureau_code || ' - ' || b.prefecture,
      'email', COALESCE(b.president_email, 'N/A'),
      'phone', COALESCE(b.president_phone, 'N/A'),
      'custom_id', b.bureau_code,
      'type', 'bureau'
    ) INTO v_receiver_info
    FROM bureau_syndicats b
    WHERE b.id = v_receiver_wallet.owner_id;
  ELSIF v_receiver_wallet.wallet_type = 'agent' THEN
    SELECT jsonb_build_object(
      'id', a.id,
      'name', a.name,
      'email', COALESCE(a.email, 'N/A'),
      'phone', COALESCE(a.phone, 'N/A'),
      'custom_id', a.agent_code,
      'type', 'agent'
    ) INTO v_receiver_info
    FROM agents_management a
    WHERE a.id = v_receiver_wallet.owner_id;
  ELSE
    SELECT jsonb_build_object(
      'id', p.id,
      'name', COALESCE(p.first_name || ' ' || p.last_name, 'Non renseigné'),
      'email', COALESCE(p.email, 'N/A'),
      'phone', COALESCE(p.phone, 'N/A'),
      'custom_id', COALESCE(p.custom_id, p.public_id),
      'type', 'user'
    ) INTO v_receiver_info
    FROM profiles p
    WHERE p.id = v_receiver_wallet.owner_id;
  END IF;
  
  -- Calculer les frais
  v_fee_percent := get_transfer_fee_percent();
  v_fee_amount := ROUND((p_amount * v_fee_percent) / 100, 0);
  v_total_debit := p_amount + v_fee_amount;
  
  -- Vérifier le solde
  IF v_sender_wallet.balance < v_total_debit THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Solde insuffisant'
    );
  END IF;
  
  -- Vérifier le statut
  IF v_sender_wallet.wallet_status != 'active' THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Wallet expéditeur inactif'
    );
  END IF;
  
  IF v_receiver_wallet.wallet_status != 'active' THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Wallet destinataire inactif'
    );
  END IF;
  
  -- Retourner les infos du transfert
  RETURN json_build_object(
    'success', true,
    'sender', v_sender_info,
    'receiver', v_receiver_info,
    'amount', p_amount,
    'fee', v_fee_amount,
    'total_debit', v_total_debit,
    'currency', p_currency,
    'sender_balance', v_sender_wallet.balance,
    'sender_wallet_id', v_sender_wallet.wallet_id,
    'sender_wallet_type', v_sender_wallet.wallet_type,
    'receiver_wallet_id', v_receiver_wallet.wallet_id,
    'receiver_wallet_type', v_receiver_wallet.wallet_type
  );
END;
$$;

COMMENT ON FUNCTION preview_wallet_transfer_by_code(TEXT, TEXT, NUMERIC, VARCHAR) IS 'Prévisualise un transfert entre wallets (supporte bureaux, agents, users)';

-- Permissions
GRANT EXECUTE ON FUNCTION find_wallet_by_code(TEXT, VARCHAR) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION preview_wallet_transfer_by_code(TEXT, TEXT, NUMERIC, VARCHAR) TO authenticated, anon;
