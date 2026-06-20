-- 💸 REMBOURSEMENT ATOMIQUE DE L'ACHETEUR À L'ANNULATION
--
-- BUG CRITIQUE : à l'annulation d'une commande, la route mettait escrow.status='refunded' SANS
-- recréditer le wallet de l'acheteur. Pour un paiement wallet, l'acheteur avait été débité par
-- create_order_core → il PERDAIT son argent. Ce RPC recrédite l'acheteur (le montant réellement
-- débité, dans la devise débitée) et passe l'escrow 'refunded', en UNE transaction (atomique).
--
-- NB : la commission acheteur (frais de service plateforme) n'est PAS remboursée (modèle standard).
-- Pour un COD/paiement externe (buyer_debit_amount NULL), aucun crédit wallet — seul le statut change.

CREATE OR REPLACE FUNCTION public.refund_order_escrow(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow         RECORD;
  v_refund_amount  numeric;
  v_refund_currency text;
  v_payer          uuid;
BEGIN
  SELECT * INTO v_escrow
  FROM public.escrow_transactions
  WHERE order_id = p_order_id AND status IN ('held', 'pending')
  FOR UPDATE;

  IF NOT FOUND THEN
    -- Rien à rembourser (déjà traité, libéré, ou COD sans escrow actif).
    RETURN jsonb_build_object('success', true, 'skipped', true);
  END IF;

  v_payer           := COALESCE(v_escrow.payer_id, v_escrow.buyer_id);
  v_refund_amount   := COALESCE(v_escrow.buyer_debit_amount, 0);          -- ce qui a été débité du wallet
  v_refund_currency := COALESCE(v_escrow.buyer_debit_currency, v_escrow.currency, 'GNF');

  IF v_payer IS NOT NULL AND v_refund_amount > 0 THEN
    UPDATE public.wallets
    SET balance = balance + v_refund_amount, updated_at = now()
    WHERE user_id = v_payer AND currency = v_refund_currency;
    IF NOT FOUND THEN
      INSERT INTO public.wallets (user_id, balance, currency, wallet_status)
      VALUES (v_payer, v_refund_amount, v_refund_currency, 'active');
    END IF;

    INSERT INTO public.wallet_transactions (
      transaction_id, sender_user_id, receiver_user_id, transaction_type,
      amount, net_amount, currency, status, description, metadata)
    VALUES (
      'rfnd-' || left(replace(gen_random_uuid()::text, '-', ''), 44),
      NULL, v_payer, 'refund', v_refund_amount, v_refund_amount, v_refund_currency, 'completed',
      'Remboursement commande annulée',
      jsonb_build_object('order_id', p_order_id, 'escrow_id', v_escrow.id, 'source', 'refund_order_escrow'));
  END IF;

  UPDATE public.escrow_transactions
  SET status = 'refunded', released_at = now(), updated_at = now()
  WHERE id = v_escrow.id;

  RETURN jsonb_build_object('success', true, 'refunded_amount', v_refund_amount, 'currency', v_refund_currency);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.refund_order_escrow(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refund_order_escrow(uuid) TO service_role;

SELECT 'refund_order_escrow créé — recrédit acheteur atomique à l''annulation.' AS status;
