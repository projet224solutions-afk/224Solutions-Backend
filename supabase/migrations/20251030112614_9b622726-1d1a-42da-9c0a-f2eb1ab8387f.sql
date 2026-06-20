-- Corriger la fonction preview_wallet_transfer pour permettre les transferts vers des utilisateurs sans wallet
CREATE OR REPLACE FUNCTION preview_wallet_transfer(
  p_sender_id UUID,
  p_receiver_id UUID,
  p_amount DECIMAL
)
RETURNS JSON AS $$
DECLARE
  v_sender_balance DECIMAL;
  v_receiver_exists BOOLEAN;
  v_fee_percent DECIMAL;
  v_fee_amount DECIMAL;
  v_total_debit DECIMAL;
  v_amount_received DECIMAL;
  v_balance_after DECIMAL;
  v_result JSON;
BEGIN
  -- Vérifier que l'expéditeur et le destinataire sont différents
  IF p_sender_id = p_receiver_id THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Vous ne pouvez pas vous transférer de l''argent à vous-même'
    );
  END IF;

  -- Récupérer le solde de l'expéditeur (toujours en GNF)
  SELECT balance INTO v_sender_balance
  FROM wallets
  WHERE user_id = p_sender_id AND currency = 'GNF';

  IF v_sender_balance IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Wallet introuvable pour l''expéditeur'
    );
  END IF;

  -- Vérifier si le destinataire existe dans profiles
  SELECT EXISTS(SELECT 1 FROM profiles WHERE id = p_receiver_id) INTO v_receiver_exists;
  
  IF NOT v_receiver_exists THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Le destinataire est introuvable'
    );
  END IF;

  -- Récupérer le taux de frais
  SELECT COALESCE(
    (SELECT setting_value::DECIMAL FROM system_settings WHERE setting_key = 'transfer_fee_percent'),
    1.0
  ) INTO v_fee_percent;

  -- Calculer les frais et le total
  v_fee_amount := ROUND((p_amount * v_fee_percent / 100), 2);
  v_total_debit := p_amount + v_fee_amount;
  v_amount_received := p_amount;
  v_balance_after := v_sender_balance - v_total_debit;

  -- Vérifier le solde suffisant
  IF v_balance_after < 0 THEN
    RETURN json_build_object(
      'success', false,
      'error', format('Solde insuffisant. Solde: %s GNF, Requis: %s GNF', v_sender_balance, v_total_debit)
    );
  END IF;

  -- Construire le résultat de succès
  v_result := json_build_object(
    'success', true,
    'amount', p_amount,
    'fee_percent', v_fee_percent,
    'fee_amount', v_fee_amount,
    'total_debit', v_total_debit,
    'amount_received', v_amount_received,
    'current_balance', v_sender_balance,
    'balance_after', v_balance_after,
    'currency', 'GNF',
    'receiver_wallet_exists', EXISTS(SELECT 1 FROM wallets WHERE user_id = p_receiver_id AND currency = 'GNF')
  );

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;