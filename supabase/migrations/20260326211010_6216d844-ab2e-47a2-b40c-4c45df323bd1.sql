-- Fix: Update existing escrow_transactions that have buyer_id/seller_id but missing payer_id/receiver_id
UPDATE escrow_transactions 
SET payer_id = buyer_id 
WHERE payer_id IS NULL AND buyer_id IS NOT NULL;

UPDATE escrow_transactions 
SET receiver_id = seller_id 
WHERE receiver_id IS NULL AND seller_id IS NOT NULL;

-- Fix the confirm_delivery_and_release_escrow RPC to check both payer_id and buyer_id
CREATE OR REPLACE FUNCTION confirm_delivery_and_release_escrow(
  p_escrow_id UUID,
  p_customer_id UUID,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow RECORD;
  v_commission_amount NUMERIC;
  v_vendor_amount NUMERIC;
  v_vendor_wallet_id BIGINT;
  v_result JSON;
BEGIN
  -- Récupérer les détails de l'escrow
  SELECT * INTO v_escrow
  FROM escrow_transactions
  WHERE id = p_escrow_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction escrow introuvable';
  END IF;

  -- Vérifier que c'est bien le client (check payer_id OR buyer_id)
  IF COALESCE(v_escrow.payer_id, v_escrow.buyer_id) != p_customer_id THEN
    RAISE EXCEPTION 'Non autorisé: vous n''êtes pas le client de cette transaction';
  END IF;

  -- Vérifier le statut (doit être pending ou held)
  IF v_escrow.status NOT IN ('pending', 'held') THEN
    RAISE EXCEPTION 'Cette transaction ne peut pas être libérée (statut: %)', v_escrow.status;
  END IF;

  -- Utiliser commission_amount si disponible, sinon calculer 2.5%
  IF v_escrow.commission_amount IS NOT NULL AND v_escrow.commission_amount > 0 THEN
    v_commission_amount := v_escrow.commission_amount;
  ELSE
    v_commission_amount := v_escrow.amount * 0.025;
  END IF;
  v_vendor_amount := v_escrow.amount - v_commission_amount;

  -- Récupérer l'ID du wallet du vendeur (check receiver_id OR seller_id)
  SELECT id INTO v_vendor_wallet_id
  FROM wallets
  WHERE user_id = COALESCE(v_escrow.receiver_id, v_escrow.seller_id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Portefeuille du vendeur introuvable pour user_id: %', COALESCE(v_escrow.receiver_id, v_escrow.seller_id);
  END IF;

  -- Créditer le portefeuille du vendeur
  UPDATE wallets
  SET 
    balance = balance + v_vendor_amount,
    updated_at = NOW()
  WHERE user_id = COALESCE(v_escrow.receiver_id, v_escrow.seller_id);

  -- Créditer la commission au portefeuille plateforme (PDG)
  UPDATE wallets
  SET 
    balance = balance + v_commission_amount,
    updated_at = NOW()
  WHERE user_id = (
    SELECT user_id FROM pdg_management WHERE is_active = true LIMIT 1
  );

  -- Mettre à jour le statut de l'escrow
  UPDATE escrow_transactions
  SET 
    status = 'released',
    released_at = NOW(),
    updated_at = NOW(),
    notes = COALESCE(p_notes, notes)
  WHERE id = p_escrow_id;

  -- Enregistrer dans les logs
  INSERT INTO escrow_logs (escrow_id, action, performed_by, note)
  VALUES (
    p_escrow_id,
    'customer_release',
    p_customer_id,
    p_notes
  );

  -- Créer la transaction wallet pour le vendeur
  INSERT INTO wallet_transactions (
    transaction_id,
    receiver_wallet_id,
    amount,
    fee,
    net_amount,
    currency,
    transaction_type,
    status,
    description,
    metadata
  )
  VALUES (
    generate_transaction_id(),
    v_vendor_wallet_id,
    v_escrow.amount,
    v_commission_amount,
    v_vendor_amount,
    COALESCE(v_escrow.currency, 'GNF'),
    'escrow_release',
    'completed',
    'Fonds libérés de l''escrow - Confirmation client',
    jsonb_build_object(
      'escrow_id', p_escrow_id,
      'commission', v_commission_amount,
      'vendor_amount', v_vendor_amount,
      'confirmed_by', 'customer',
      'order_id', v_escrow.order_id
    )
  );

  v_result := json_build_object(
    'success', true,
    'escrow_id', p_escrow_id,
    'vendor_amount', v_vendor_amount,
    'commission_amount', v_commission_amount,
    'released_at', NOW()
  );

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RAISE;
END;
$$;