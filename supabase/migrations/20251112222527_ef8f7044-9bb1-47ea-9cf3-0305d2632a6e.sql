-- Corriger la fonction confirm_delivery_and_release_escrow pour utiliser la bonne structure de wallet_transactions
CREATE OR REPLACE FUNCTION public.confirm_delivery_and_release_escrow(
  p_escrow_id UUID,
  p_customer_id UUID,
  p_notes TEXT DEFAULT 'Livraison confirmée par le client'
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
  v_vendor_wallet_id UUID;
  v_result JSON;
BEGIN
  -- Récupérer les détails de l'escrow
  SELECT * INTO v_escrow
  FROM escrow_transactions
  WHERE id = p_escrow_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Transaction escrow introuvable';
  END IF;

  -- Vérifier que c'est bien le client de cette transaction
  IF v_escrow.payer_id != p_customer_id THEN
    RAISE EXCEPTION 'Non autorisé: vous n''êtes pas le client de cette transaction';
  END IF;

  -- Vérifier le statut (doit être pending ou held)
  IF v_escrow.status NOT IN ('pending', 'held') THEN
    RAISE EXCEPTION 'Cette transaction ne peut pas être libérée (statut: %)', v_escrow.status;
  END IF;

  -- Calculer la commission (2.5%)
  v_commission_amount := v_escrow.amount * 0.025;
  v_vendor_amount := v_escrow.amount - v_commission_amount;

  -- Récupérer l'ID du wallet du vendeur
  SELECT id INTO v_vendor_wallet_id
  FROM wallets
  WHERE user_id = v_escrow.receiver_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Portefeuille du vendeur introuvable';
  END IF;

  -- Créditer le portefeuille du vendeur
  UPDATE wallets
  SET 
    balance = balance + v_vendor_amount,
    updated_at = NOW()
  WHERE user_id = v_escrow.receiver_id;

  -- Créditer la commission au portefeuille plateforme
  UPDATE wallets
  SET 
    balance = balance + v_commission_amount,
    updated_at = NOW()
  WHERE user_id = (
    SELECT id FROM profiles WHERE role = 'admin' LIMIT 1
  );

  -- Mettre à jour le statut de l'escrow
  UPDATE escrow_transactions
  SET 
    status = 'released',
    released_at = NOW(),
    updated_at = NOW()
  WHERE id = p_escrow_id;

  -- Enregistrer dans les logs
  INSERT INTO escrow_logs (escrow_id, action, performed_by, note)
  VALUES (
    p_escrow_id,
    'customer_release',
    p_customer_id,
    p_notes
  );

  -- Créer la transaction wallet pour le vendeur avec la bonne structure
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
    v_escrow.currency,
    'escrow_release',
    'completed',
    'Fonds libérés de l''escrow - Confirmation client',
    jsonb_build_object(
      'escrow_id', p_escrow_id,
      'commission', v_commission_amount,
      'confirmed_by', 'customer'
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