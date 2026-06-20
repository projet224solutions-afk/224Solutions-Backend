-- 🩹 CORRECTIF — refund_order_escrow : même problème de contrainte CHECK (net_amount = amount - fee)
-- que les libérations. L'insert mettait amount = montant débité (devise débit) mais net_amount =
-- montant CRÉDITÉ CONVERTI → viole la contrainte si l'acheteur a changé de devise depuis l'achat.
--
-- FIX : ligne d'historique EN DEVISE DU DÉBIT (amount = net_amount = montant débité, net = amount - 0),
-- currency = devise débit. Le SOLDE est recrédité du montant CONVERTI par credit_user_wallet_safe
-- (inchangé) ; le montant converti est dans metadata.credited.

CREATE OR REPLACE FUNCTION public.refund_order_escrow(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow          RECORD;
  v_refund_amount   numeric;
  v_refund_currency text;
  v_payer           uuid;
  v_res             jsonb;
BEGIN
  SELECT * INTO v_escrow
  FROM public.escrow_transactions
  WHERE order_id = p_order_id AND status IN ('held', 'pending')
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', true, 'skipped', true);
  END IF;

  v_payer           := COALESCE(v_escrow.payer_id, v_escrow.buyer_id);
  v_refund_amount   := COALESCE(v_escrow.buyer_debit_amount, 0);
  v_refund_currency := COALESCE(v_escrow.buyer_debit_currency, v_escrow.currency, 'GNF');

  IF v_payer IS NOT NULL AND v_refund_amount > 0 THEN
    -- Recrédit converti dans la devise du wallet de l'acheteur (anti-doublon + conversion)
    v_res := public.credit_user_wallet_safe(v_payer, v_refund_amount, v_refund_currency);

    -- Ligne d'historique EN DEVISE DU DÉBIT : net_amount = amount (pas de fee) → contrainte respectée.
    INSERT INTO public.wallet_transactions (
      transaction_id, sender_user_id, receiver_user_id, transaction_type,
      amount, net_amount, currency, status, description, metadata)
    VALUES (
      'rfnd-' || left(replace(gen_random_uuid()::text, '-', ''), 44),
      NULL, v_payer, 'refund', v_refund_amount, v_refund_amount,
      v_refund_currency, 'completed', 'Remboursement commande annulée',
      jsonb_build_object('order_id', p_order_id, 'escrow_id', v_escrow.id,
                         'credited', (v_res->>'credited')::numeric, 'credited_currency', v_res->>'currency',
                         'original_currency', v_refund_currency, 'source', 'refund_order_escrow'));
  END IF;

  UPDATE public.escrow_transactions
  SET status = 'refunded', released_at = now(), updated_at = now()
  WHERE id = v_escrow.id;

  RETURN jsonb_build_object('success', true, 'refunded_amount', v_refund_amount, 'currency', v_refund_currency);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

SELECT 'refund_order_escrow : ligne d''historique en devise du débit (net = amount), solde recrédité converti.' AS status;
