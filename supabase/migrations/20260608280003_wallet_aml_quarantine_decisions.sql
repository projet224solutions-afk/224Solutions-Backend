-- ============================================================================
-- AML — DÉCISIONS PDG SUR LA QUARANTAINE (atomique)
-- ----------------------------------------------------------------------------
-- release_quarantined_funds : le PDG juge la provenance légitime → les fonds sont
--   recrédités au wallet (en TRAÇANT une wallet_transactions, donc la hausse de
--   solde est légitime et NE déclenche PAS untraced_increase) ; le crédit ignore
--   volontairement le plafond (décision PDG assumée). Idempotent (déjà released).
-- reject_quarantined_funds : provenance non justifiée → la quarantaine est marquée
--   rejetée ; les fonds NE sont PAS recrédités (restent hors solde dépensable).
-- Non destructif, rejouable.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.release_quarantined_funds(
  p_id    uuid,
  p_admin uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_q      RECORD;
  v_txn_id text;
BEGIN
  SELECT * INTO v_q FROM public.wallet_quarantined_funds WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Quarantaine introuvable');
  END IF;
  IF v_q.status <> 'pending' THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'status', v_q.status);  -- idempotent
  END IF;

  -- Recrédit DIRECT du wallet (décision PDG → on ignore le plafond) + ligne d'historique (traçabilité).
  UPDATE public.wallets SET balance = COALESCE(balance, 0) + v_q.amount, updated_at = now()
  WHERE id = v_q.wallet_id;

  v_txn_id := 'qrel-' || left(replace(gen_random_uuid()::text, '-', ''), 44);
  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_wallet_id, receiver_user_id, amount, net_amount, currency,
    transaction_type, status, description, metadata)
  VALUES (
    v_txn_id, v_q.wallet_id, v_q.user_id, v_q.amount, v_q.amount, v_q.currency,
    'deposit', 'completed', 'Libération de fonds en quarantaine (validation PDG)',
    jsonb_build_object('source', 'quarantine_release', 'quarantine_id', p_id,
      'source_type', v_q.source_type, 'released_by', p_admin, 'notes', p_notes));

  UPDATE public.wallet_quarantined_funds
  SET status = 'released', reviewed_by = p_admin, reviewed_at = now(),
      release_transaction_id = v_txn_id, notes = COALESCE(p_notes, notes)
  WHERE id = p_id;

  RETURN jsonb_build_object('success', true, 'released_amount', v_q.amount, 'currency', v_q.currency,
    'transaction_id', v_txn_id, 'wallet_id', v_q.wallet_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_quarantined_funds(
  p_id    uuid,
  p_admin uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_q RECORD;
BEGIN
  SELECT * INTO v_q FROM public.wallet_quarantined_funds WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Quarantaine introuvable');
  END IF;
  IF v_q.status <> 'pending' THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'status', v_q.status);
  END IF;

  UPDATE public.wallet_quarantined_funds
  SET status = 'rejected', reviewed_by = p_admin, reviewed_at = now(), notes = COALESCE(p_notes, notes)
  WHERE id = p_id;

  RETURN jsonb_build_object('success', true, 'rejected_amount', v_q.amount, 'currency', v_q.currency);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.release_quarantined_funds(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_quarantined_funds(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.release_quarantined_funds(uuid, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.reject_quarantined_funds(uuid, uuid, text) TO service_role;

SELECT 'RPC quarantaine : release_quarantined_funds + reject_quarantined_funds.' AS status;
