-- DURCISSEMENT ATOMIQUE du système de litige/remboursement.
--
-- AVANT (Edge resolve-dispute) : séquence d'updates SÉPARÉS, NON atomique, et le
-- "refund_to_buyer" ne faisait qu'un UPDATE escrow status='refunded' SANS créditer
-- le wallet de l'acheteur → l'acheteur n'était JAMAIS réellement remboursé + états
-- incohérents possibles si un update échoue au milieu + double-résolution possible.
--
-- APRÈS : une fonction unique, tout-ou-rien (1 transaction), avec verrou de ligne
-- (compare-and-set) — impossible de résoudre/rembourser deux fois ; soit tout
-- réussit, soit tout est annulé.

-- ── 1. Résolution atomique d'un litige escrow ────────────────────────────
CREATE OR REPLACE FUNCTION public.resolve_escrow_dispute(
  p_dispute_id  uuid,
  p_resolution  text,            -- 'refund_to_buyer' | 'release_to_seller'
  p_resolver_id uuid,
  p_notes       text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dispute RECORD;
  v_escrow  RECORD;
  v_res     jsonb := NULL;
BEGIN
  IF p_resolution NOT IN ('refund_to_buyer', 'release_to_seller') THEN
    RAISE EXCEPTION 'invalid_resolution';
  END IF;

  -- Verrou + garde anti-double-résolution : 2 PDG simultanés → un seul gagne,
  -- l'autre voit le litige déjà 'resolved' et est rejeté (pas de double mouvement).
  SELECT * INTO v_dispute FROM public.escrow_disputes WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispute_not_found'; END IF;
  IF v_dispute.status = 'resolved' THEN RAISE EXCEPTION 'already_resolved'; END IF;

  SELECT * INTO v_escrow FROM public.escrow_transactions WHERE id = v_dispute.escrow_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'escrow_not_found'; END IF;

  IF p_resolution = 'refund_to_buyer' THEN
    -- Remboursement réel et atomique : crédite le wallet acheteur + escrow 'refunded'.
    v_res := public.refund_order_escrow(v_escrow.order_id);
    -- Ne JAMAIS marquer 'resolved' sans remboursement effectif (escrow déjà libéré/COD).
    IF COALESCE((v_res->>'skipped')::boolean, false) THEN
      RAISE EXCEPTION 'escrow_not_refundable_status_%', v_escrow.status;
    END IF;
    IF v_escrow.order_id IS NOT NULL THEN
      UPDATE public.orders
      SET status = 'cancelled', payment_status = 'refunded', updated_at = now()
      WHERE id = v_escrow.order_id;
    END IF;
  ELSE
    -- Libération atomique au vendeur (net + commission via la primitive existante).
    PERFORM public.release_escrow(v_escrow.id, 2.5, p_resolver_id);
    IF v_escrow.order_id IS NOT NULL THEN
      UPDATE public.orders
      SET status = 'delivered', payment_status = 'paid', updated_at = now()
      WHERE id = v_escrow.order_id;
    END IF;
  END IF;

  -- Marquer le litige résolu — DANS LA MÊME TRANSACTION que le mouvement d'argent.
  UPDATE public.escrow_disputes
  SET status = 'resolved', resolution = p_resolution, resolution_notes = p_notes,
      resolved_by = p_resolver_id, resolved_at = now()
  WHERE id = p_dispute_id;

  RETURN jsonb_build_object('success', true, 'resolution', p_resolution, 'refund', v_res);
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_escrow_dispute(uuid, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_escrow_dispute(uuid, text, uuid, text) TO service_role;

-- ── 2. Garde anti-double-litige (atomicité de l'OUVERTURE d'un litige) ───
-- Impossible d'avoir 2 litiges NON résolus sur le même escrow, même en cas de
-- double-clic / requêtes concurrentes (la 2e insertion échoue sur l'unicité).
CREATE UNIQUE INDEX IF NOT EXISTS uniq_open_escrow_dispute_per_escrow
  ON public.escrow_disputes (escrow_id)
  WHERE status <> 'resolved';
