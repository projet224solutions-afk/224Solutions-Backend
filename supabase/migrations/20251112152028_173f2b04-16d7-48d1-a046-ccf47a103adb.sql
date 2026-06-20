-- Fix: Remove function overloading for refund_escrow
-- Drop all versions of refund_escrow to avoid overloading issues

DROP FUNCTION IF EXISTS public.refund_escrow(p_escrow_id UUID);
DROP FUNCTION IF EXISTS public.refund_escrow(p_escrow_id UUID, p_reason TEXT);

-- Create a single version with optional reason parameter
CREATE OR REPLACE FUNCTION public.refund_escrow(
  p_escrow_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow RECORD;
  v_payer_wallet_id UUID;
  v_pdg_wallet_id UUID;
BEGIN
  -- Récupérer l'escrow
  SELECT * INTO v_escrow
  FROM escrow_transactions
  WHERE id = p_escrow_id AND status IN ('pending', 'held');
  
  IF v_escrow IS NULL THEN
    RAISE EXCEPTION 'Escrow introuvable ou déjà traité';
  END IF;
  
  -- Récupérer le wallet du payeur
  SELECT id INTO v_payer_wallet_id
  FROM wallets
  WHERE user_id = v_escrow.payer_id AND currency = v_escrow.currency;
  
  IF v_payer_wallet_id IS NULL THEN
    RAISE EXCEPTION 'Wallet du payeur introuvable';
  END IF;
  
  -- Récupérer le wallet PDG
  SELECT setting_value::UUID INTO v_pdg_wallet_id
  FROM system_settings
  WHERE setting_key = 'pdg_wallet_id';
  
  -- Si wallet PDG existe, débiter
  IF v_pdg_wallet_id IS NOT NULL THEN
    UPDATE wallets
    SET balance = balance - v_escrow.amount, updated_at = now()
    WHERE id = v_pdg_wallet_id;
  END IF;
  
  -- Créditer le payeur (remboursement)
  UPDATE wallets
  SET balance = balance + v_escrow.amount, updated_at = now()
  WHERE id = v_payer_wallet_id;
  
  -- Mettre à jour l'escrow
  UPDATE escrow_transactions
  SET 
    status = 'refunded',
    refunded_at = now(),
    refund_reason = p_reason,
    updated_at = now()
  WHERE id = p_escrow_id;
  
  -- Log l'action
  INSERT INTO escrow_logs (escrow_id, action, performed_by, note, metadata)
  VALUES (
    p_escrow_id,
    'refunded',
    auth.uid(),
    COALESCE(p_reason, 'Remboursement effectué'),
    jsonb_build_object('reason', p_reason)
  );
  
  RETURN TRUE;
END;
$$;