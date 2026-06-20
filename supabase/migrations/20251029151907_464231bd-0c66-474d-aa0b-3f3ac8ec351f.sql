-- Correction des fonctions pour utiliser wallet_status au lieu de status

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
  v_sender_id UUID;
  v_receiver_id UUID;
  v_sender_info JSONB;
  v_receiver_info JSONB;
  v_fee_percent NUMERIC;
  v_fee_amount NUMERIC;
  v_total_debit NUMERIC;
  v_sender_balance NUMERIC;
  v_sender_status VARCHAR;
BEGIN
  -- Trouver l'expéditeur
  v_sender_id := find_user_by_code(p_sender_code);
  
  IF v_sender_id IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Expéditeur introuvable: ' || p_sender_code
    );
  END IF;
  
  -- Trouver le destinataire
  v_receiver_id := find_user_by_code(p_receiver_code);
  
  IF v_receiver_id IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Destinataire introuvable: ' || p_receiver_code
    );
  END IF;
  
  -- Vérifier que ce ne sont pas la même personne
  IF v_sender_id = v_receiver_id THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Impossible de transférer vers votre propre compte'
    );
  END IF;
  
  -- Récupérer les infos de l'expéditeur
  SELECT jsonb_build_object(
    'id', p.id,
    'name', COALESCE(p.first_name || ' ' || p.last_name, 'Non renseigné'),
    'email', COALESCE(p.email, 'Non renseigné'),
    'phone', COALESCE(p.phone, 'Non renseigné'),
    'custom_id', COALESCE(p.custom_id, p.public_id)
  ) INTO v_sender_info
  FROM profiles p
  WHERE p.id = v_sender_id;
  
  -- Récupérer les infos du destinataire
  SELECT jsonb_build_object(
    'id', p.id,
    'name', COALESCE(p.first_name || ' ' || p.last_name, 'Non renseigné'),
    'email', COALESCE(p.email, 'Non renseigné'),
    'phone', COALESCE(p.phone, 'Non renseigné'),
    'custom_id', COALESCE(p.custom_id, p.public_id)
  ) INTO v_receiver_info
  FROM profiles p
  WHERE p.id = v_receiver_id;
  
  -- Obtenir le taux de commission
  v_fee_percent := get_transfer_fee_percent();
  
  -- Calculer les frais
  v_fee_amount := ROUND((p_amount * v_fee_percent) / 100, 0);
  v_total_debit := p_amount + v_fee_amount;
  
  -- Vérifier le wallet de l'expéditeur (utiliser wallet_status au lieu de status)
  SELECT balance, wallet_status INTO v_sender_balance, v_sender_status
  FROM wallets
  WHERE user_id = v_sender_id AND currency = p_currency;
  
  IF v_sender_balance IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Wallet expéditeur introuvable'
    );
  END IF;
  
  IF v_sender_status != 'active' AND v_sender_status IS NOT NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Wallet expéditeur inactif'
    );
  END IF;
  
  -- Vérifier le solde
  IF v_sender_balance < v_total_debit THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Solde insuffisant',
      'current_balance', v_sender_balance,
      'required', v_total_debit,
      'shortage', v_total_debit - v_sender_balance
    );
  END IF;
  
  -- Retourner la prévisualisation complète
  RETURN json_build_object(
    'success', true,
    'sender', v_sender_info,
    'receiver', v_receiver_info,
    'amount', p_amount,
    'fee_percent', v_fee_percent,
    'fee_amount', v_fee_amount,
    'total_debit', v_total_debit,
    'amount_received', p_amount,
    'current_balance', v_sender_balance,
    'balance_after', v_sender_balance - v_total_debit
  );
END;
$$;

-- Pas de changement nécessaire pour process_wallet_transfer_with_fees
-- car elle n'utilise pas wallet_status (elle crée/update juste)

-- Accorder les permissions
GRANT EXECUTE ON FUNCTION preview_wallet_transfer_by_code(TEXT, TEXT, NUMERIC, VARCHAR) TO authenticated, anon;