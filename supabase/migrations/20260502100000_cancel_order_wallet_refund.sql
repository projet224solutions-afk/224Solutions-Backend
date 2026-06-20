-- ============================================================
-- FIX: Remboursement wallet automatique à l'annulation commande
-- ============================================================
-- PROBLÈME: La route backend POST /api/orders/:orderId/cancel marquait
-- l'escrow "refunded" mais ne créditait JAMAIS le wallet du client.
-- La logique de remboursement wallet existait uniquement dans la Edge Function
-- cancel-order (non appelée par le frontend).
--
-- FIX: Nouveau RPC cancel_order_and_refund_wallet — appelé par la route backend.
-- Gère atomiquement (dans une transaction) :
--   1. Vérification escrow éligible (carte / Orange Money / wallet uniquement)
--   2. Crédit wallet client (INSERT ON CONFLICT DO UPDATE — atomique, pas de race condition)
--   3. Mise à jour escrow → "refunded" ou "cancelled" selon le cas
--   4. Log d'audit dans escrow_action_logs
--
-- LOGIQUE DE REMBOURSEMENT:
--   status = 'held'    → argent réellement encaissé (carte, Orange Money, wallet)
--                        → remboursement wallet requis ✅
--   status = 'pending' → escrow virtuel COD (paiement à la livraison)
--                        → aucun argent reçu → PAS de remboursement wallet ❌
--                        → on passe juste le statut à 'cancelled'
--
-- Cette distinction est posée à la création de commande dans orders.routes.ts :
--   payment_method = 'cash'  → escrow.status = 'pending'
--   payment_method ≠ 'cash'  → escrow.status = 'held'

CREATE OR REPLACE FUNCTION public.cancel_order_and_refund_wallet(
  p_order_id   uuid,
  p_user_id    uuid,    -- user_id du client qui annule (pour audit)
  p_reason     text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_escrow      RECORD;
  v_refunded    boolean := false;
  v_amount      numeric := 0;
  v_currency    text    := 'GNF';
  v_is_cod      boolean := false;
BEGIN
  -- Récupérer l'escrow lié à cette commande (avec metadata pour détecter COD)
  SELECT id, payer_id, amount, currency, status, metadata
  INTO v_escrow
  FROM public.escrow_transactions
  WHERE order_id = p_order_id
  LIMIT 1;

  -- Rien à faire si aucun escrow
  IF v_escrow.id IS NULL THEN
    RETURN jsonb_build_object(
      'success',  true,
      'refunded', false,
      'amount',   0,
      'currency', 'GNF',
      'reason',   'no_escrow'
    );
  END IF;

  -- Détecter paiement à la livraison :
  --   - escrow.status = 'pending' (posé par orders.routes.ts ligne 617)
  --   - OU metadata.payment_type = 'cash_on_delivery' (double sécurité)
  v_is_cod := (
    v_escrow.status = 'pending'
    OR COALESCE(v_escrow.metadata->>'payment_type', '') = 'cash_on_delivery'
  );

  v_amount   := COALESCE(v_escrow.amount, 0);
  v_currency := COALESCE(v_escrow.currency, 'GNF');

  IF v_is_cod THEN
    -- ─── Paiement à la livraison ─────────────────────────────────────────────
    -- Aucun argent n'a été encaissé → pas de remboursement wallet.
    -- On passe juste l'escrow virtuel à 'cancelled'.
    UPDATE public.escrow_transactions
    SET
      status      = 'cancelled',
      notes       = COALESCE(p_reason, 'Annulation commande COD par le client'),
      updated_at  = NOW()
    WHERE id = v_escrow.id;

    INSERT INTO public.escrow_action_logs (
      escrow_id, action_type, performed_by, notes, metadata
    ) VALUES (
      v_escrow.id,
      'cancelled',
      p_user_id,
      'Annulation COD — aucun remboursement wallet (paiement à la livraison)',
      jsonb_build_object('order_id', p_order_id, 'cod', true)
    );

  ELSIF v_escrow.status = 'held' THEN
    -- ─── Paiement réel (carte / Orange Money / wallet) ───────────────────────
    -- Argent encaissé et mis en séquestre → remboursement dans le wallet client.

    IF v_amount > 0 AND v_escrow.payer_id IS NOT NULL THEN
      -- Crédit atomique : INSERT ON CONFLICT évite toute race condition
      INSERT INTO public.wallets (user_id, balance, currency, created_at, updated_at)
      VALUES (v_escrow.payer_id, v_amount, v_currency, NOW(), NOW())
      ON CONFLICT (user_id)
      DO UPDATE SET
        balance    = public.wallets.balance + EXCLUDED.balance,
        updated_at = NOW();

      v_refunded := true;
    END IF;

    -- Passer l'escrow à 'refunded'
    UPDATE public.escrow_transactions
    SET
      status      = 'refunded',
      refunded_at = NOW(),
      notes       = COALESCE(p_reason, 'Annulation par le client'),
      updated_at  = NOW()
    WHERE id = v_escrow.id;

    -- Log d'audit
    INSERT INTO public.escrow_action_logs (
      escrow_id, action_type, performed_by, notes, metadata
    ) VALUES (
      v_escrow.id,
      'refunded',
      p_user_id,
      COALESCE(p_reason, 'Annulation de commande — remboursement wallet'),
      jsonb_build_object(
        'order_id',  p_order_id,
        'amount',    v_amount,
        'currency',  v_currency,
        'payer_id',  v_escrow.payer_id,
        'refunded',  v_refunded
      )
    );

  ELSE
    -- Escrow dans un statut non éligible (déjà released, refunded, dispute, etc.)
    -- On ne fait rien, on log silencieusement.
    INSERT INTO public.escrow_action_logs (
      escrow_id, action_type, performed_by, notes, metadata
    ) VALUES (
      v_escrow.id,
      'cancel_skipped',
      p_user_id,
      'Annulation ignorée — statut escrow non éligible : ' || v_escrow.status,
      jsonb_build_object('order_id', p_order_id, 'escrow_status', v_escrow.status)
    );
  END IF;

  RETURN jsonb_build_object(
    'success',   true,
    'refunded',  v_refunded,
    'amount',    CASE WHEN v_refunded THEN v_amount ELSE 0 END,
    'currency',  v_currency,
    'cod',       v_is_cod
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error',   SQLERRM
  );
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_order_and_refund_wallet(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_order_and_refund_wallet(uuid, uuid, text) TO service_role;
