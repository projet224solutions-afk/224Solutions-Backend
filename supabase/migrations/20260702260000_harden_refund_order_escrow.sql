-- ============================================================================
-- 🛡️ DURCISSEMENT refund_order_escrow — annulation/remboursement blindé
-- ----------------------------------------------------------------------------
-- Cause des "Échec du remboursement" : le payer était résolu à COALESCE(payer_id, buyer_id).
-- Pour les commandes non-wallet créées avant le fix, payer_id=NULL et buyer_id=customers.id
-- (≠ auth.uid()) → credit_user_wallet_safe créditait un id SANS wallet réel (ou créait un wallet
-- fantôme). On rend la résolution du payer ROBUSTE (payer_id → buyer_id → user_id du client de la
-- commande = auth.uid()), le crédit IDEMPOTENT (clé source refund/order_id) et le skip NON-fatal :
--   • carte / mobile money (buyer_debit_amount NULL) : pas de recrédit wallet (remboursement via le
--     fournisseur) → l'escrow passe 'refunded' sans erreur ;
--   • wallet : recrédit converti + idempotent ; garde ROLLBACK si le crédit devait avoir lieu et n'a
--     pas eu lieu (jamais un "refunded" sans remboursement réel).
-- Atomique (tout-ou-rien), rejouable sans double-crédit.
-- ============================================================================

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
  v_got             numeric;
BEGIN
  SELECT * INTO v_escrow
  FROM public.escrow_transactions
  WHERE order_id = p_order_id AND status IN ('held', 'pending')
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', true, 'skipped', true);
  END IF;

  -- Payer ROBUSTE : payer_id → buyer_id → user_id du client de la commande (auth.uid()).
  v_payer := v_escrow.payer_id;
  IF v_payer IS NULL THEN v_payer := v_escrow.buyer_id; END IF;
  IF v_payer IS NULL THEN
    SELECT c.user_id INTO v_payer
    FROM public.orders o JOIN public.customers c ON c.id = o.customer_id
    WHERE o.id = p_order_id;
  END IF;

  v_refund_amount   := COALESCE(v_escrow.buyer_debit_amount, 0);
  v_refund_currency := COALESCE(v_escrow.buyer_debit_currency, v_escrow.currency, 'GNF');

  -- Recrédit wallet UNIQUEMENT si l'acheteur a été débité de son wallet (montant > 0).
  IF v_payer IS NOT NULL AND v_refund_amount > 0 THEN
    -- Idempotent par (refund, order_id) : un retry ne double JAMAIS le remboursement.
    v_res := public.credit_user_wallet_safe(v_payer, v_refund_amount, v_refund_currency, 'refund', p_order_id::text);
    v_got := COALESCE((v_res->>'credited')::numeric, 0) + COALESCE((v_res->>'quarantined')::numeric, 0);

    -- Garde : si le crédit devait avoir lieu (pas un skip idempotent) mais n'a rien crédité → ROLLBACK.
    IF NOT COALESCE((v_res->>'skipped')::boolean, false) AND v_got <= 0 THEN
      RAISE EXCEPTION 'REFUND_CREDIT_ECHOUE (%)', COALESCE(v_res->>'error', '?');
    END IF;

    -- Ligne d'historique EN DEVISE DU DÉBIT (net = amount) — seulement si un crédit vient d'avoir lieu.
    IF NOT COALESCE((v_res->>'skipped')::boolean, false) THEN
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
  END IF;

  UPDATE public.escrow_transactions
  SET status = 'refunded', released_at = now(), updated_at = now()
  WHERE id = v_escrow.id;

  RETURN jsonb_build_object('success', true, 'refunded_amount', v_refund_amount, 'currency', v_refund_currency);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.refund_order_escrow(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.refund_order_escrow(uuid) TO service_role;

SELECT 'refund_order_escrow durci : payer robuste + crédit idempotent (refund/order_id) + skip non-fatal.' AS status;
