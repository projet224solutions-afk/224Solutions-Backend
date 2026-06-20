-- ============================================
-- Fix execute_atomic_wallet_transfer: wallet IDs sont BIGINT (pas UUID)
-- wallets.id est BIGSERIAL PRIMARY KEY depuis fix_wallet_system_complete
-- ============================================

CREATE OR REPLACE FUNCTION execute_atomic_wallet_transfer(
  p_sender_id UUID,
  p_receiver_id UUID,
  p_amount NUMERIC,
  p_description TEXT,
  p_sender_wallet_id BIGINT,
  p_recipient_wallet_id BIGINT,
  p_sender_balance_before NUMERIC,
  p_recipient_balance_before NUMERIC
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tx_id UUID;
  v_new_sender_balance NUMERIC;
  v_new_recipient_balance NUMERIC;
BEGIN
  v_new_sender_balance := p_sender_balance_before - p_amount;
  v_new_recipient_balance := p_recipient_balance_before + p_amount;
  v_tx_id := gen_random_uuid();

  -- Débit expéditeur avec verrou optimiste
  UPDATE wallets SET balance = v_new_sender_balance, updated_at = now()
  WHERE id = p_sender_wallet_id AND balance = p_sender_balance_before;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Concurrent modification detected';
  END IF;

  -- Crédit destinataire
  UPDATE wallets SET balance = v_new_recipient_balance, updated_at = now()
  WHERE id = p_recipient_wallet_id;

  IF NOT FOUND THEN
    -- Rollback expéditeur
    UPDATE wallets SET balance = p_sender_balance_before WHERE id = p_sender_wallet_id;
    RAISE EXCEPTION 'Recipient wallet not found';
  END IF;

  -- Enregistre dans enhanced_transactions pour l'audit
  INSERT INTO enhanced_transactions (id, sender_id, receiver_id, amount, method, status, currency, transaction_type, metadata)
  VALUES (
    v_tx_id, p_sender_id, p_receiver_id, p_amount, 'wallet', 'completed',
    (SELECT currency FROM wallets WHERE id = p_sender_wallet_id LIMIT 1),
    'transfer',
    jsonb_build_object('description', p_description, 'atomic', true)
  );

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id);
END;
$$;
