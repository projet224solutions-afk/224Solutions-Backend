-- Drop all existing versions of release_escrow_funds and refund_escrow_funds
DROP FUNCTION IF EXISTS public.release_escrow_funds(uuid, uuid) CASCADE;
DROP FUNCTION IF EXISTS public.release_escrow_funds(uuid, uuid, text) CASCADE;
DROP FUNCTION IF EXISTS public.release_escrow_funds CASCADE;

DROP FUNCTION IF EXISTS public.refund_escrow_funds(uuid, uuid, text) CASCADE;
DROP FUNCTION IF EXISTS public.refund_escrow_funds CASCADE;

-- Recreate release_escrow_funds with correct column names (payer_id, receiver_id)
CREATE OR REPLACE FUNCTION public.release_escrow_funds(
  p_escrow_id uuid, 
  p_admin_id uuid DEFAULT NULL::uuid,
  p_notes text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_escrow RECORD;
  v_is_admin BOOLEAN;
BEGIN
  -- Récupérer les détails de l'escrow
  SELECT * INTO v_escrow
  FROM escrow_transactions
  WHERE id = p_escrow_id AND status IN ('held', 'pending', 'dispute');
  
  IF v_escrow IS NULL THEN
    RAISE EXCEPTION 'Transaction escrow introuvable ou déjà traitée';
  END IF;
  
  -- Vérifier si l'utilisateur est admin/PDG (si admin_id fourni)
  IF p_admin_id IS NOT NULL THEN
    SELECT EXISTS(
      SELECT 1 FROM profiles WHERE id = p_admin_id AND role IN ('admin', 'ceo')
    ) INTO v_is_admin;
    
    IF NOT v_is_admin THEN
      RAISE EXCEPTION 'Seul un administrateur ou PDG peut libérer les fonds manuellement';
    END IF;
  END IF;
  
  -- Créditer le vendeur (receiver_id, NOT seller_id)
  UPDATE wallets
  SET balance = balance + v_escrow.amount,
      updated_at = now()
  WHERE user_id = v_escrow.receiver_id AND currency = v_escrow.currency;
  
  -- Si le wallet du vendeur n'existe pas, le créer
  IF NOT FOUND THEN
    INSERT INTO wallets (user_id, balance, currency)
    VALUES (v_escrow.receiver_id, v_escrow.amount, v_escrow.currency);
  END IF;
  
  -- Mettre à jour la transaction escrow
  UPDATE escrow_transactions
  SET status = 'released',
      released_at = now(),
      released_by = p_admin_id,
      admin_id = p_admin_id,
      admin_action = CASE WHEN p_admin_id IS NOT NULL THEN 'manual_release' ELSE 'auto_release' END,
      notes = COALESCE(p_notes, notes),
      updated_at = now()
  WHERE id = p_escrow_id;
  
  -- Logger l'action (use payer_id, NOT buyer_id)
  INSERT INTO escrow_action_logs (escrow_id, action_type, performed_by, notes, metadata)
  VALUES (
    p_escrow_id, 
    'release', 
    COALESCE(p_admin_id, v_escrow.payer_id),
    COALESCE(p_notes, 'Fonds libérés au vendeur'),
    jsonb_build_object(
      'amount', v_escrow.amount,
      'currency', v_escrow.currency,
      'receiver_id', v_escrow.receiver_id,
      'admin_release', p_admin_id IS NOT NULL
    )
  );
  
  RETURN TRUE;
END;
$$;

-- Recreate refund_escrow_funds with correct column names (payer_id)
CREATE OR REPLACE FUNCTION public.refund_escrow_funds(
  p_escrow_id uuid, 
  p_admin_id uuid, 
  p_reason text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_escrow RECORD;
BEGIN
  -- Verify admin role
  IF NOT has_role(p_admin_id, 'admin'::user_role) THEN
    RAISE EXCEPTION 'Only admins can refund escrow funds';
  END IF;

  -- Get escrow details
  SELECT * INTO v_escrow
  FROM public.escrow_transactions
  WHERE id = p_escrow_id AND status IN ('held', 'pending', 'dispute');

  IF v_escrow IS NULL THEN
    RAISE EXCEPTION 'Escrow not found or cannot be refunded';
  END IF;

  -- Refund to payer (NOT buyer_id)
  UPDATE public.wallets
  SET balance = balance + v_escrow.amount, 
      updated_at = now()
  WHERE user_id = v_escrow.payer_id AND currency = v_escrow.currency;
  
  -- Create wallet if it doesn't exist
  IF NOT FOUND THEN
    INSERT INTO public.wallets (user_id, balance, currency)
    VALUES (v_escrow.payer_id, v_escrow.amount, v_escrow.currency);
  END IF;

  -- Update escrow transaction
  UPDATE public.escrow_transactions
  SET status = 'refunded', 
      refunded_at = now(), 
      admin_id = p_admin_id,
      admin_action = 'refund', 
      notes = COALESCE(p_reason, notes),
      updated_at = now()
  WHERE id = p_escrow_id;

  -- Log the action
  INSERT INTO public.escrow_action_logs (escrow_id, action_type, performed_by, notes, metadata)
  VALUES (
    p_escrow_id, 
    'refunded', 
    p_admin_id, 
    COALESCE(p_reason, 'Remboursement effectué'),
    jsonb_build_object(
      'amount', v_escrow.amount,
      'currency', v_escrow.currency,
      'payer_id', v_escrow.payer_id
    )
  );

  RETURN TRUE;
END;
$$;

COMMENT ON FUNCTION public.release_escrow_funds IS 'Release escrow funds to receiver. Uses payer_id/receiver_id';
COMMENT ON FUNCTION public.refund_escrow_funds IS 'Refund escrow funds to payer. Uses payer_id';

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION public.release_escrow_funds TO authenticated;
GRANT EXECUTE ON FUNCTION public.release_escrow_funds TO service_role;
GRANT EXECUTE ON FUNCTION public.refund_escrow_funds TO authenticated;
GRANT EXECUTE ON FUNCTION public.refund_escrow_funds TO service_role;