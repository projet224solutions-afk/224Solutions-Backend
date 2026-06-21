-- ============================================================================
-- 🛡️ RETRAIT ATOMIQUE — RPC execute_atomic_withdrawal (débit + ledger en 1 transaction).
--
-- Avant : debitWallet (Node) faisait UPDATE balance puis INSERT ledger en 2 appels séparés →
-- si le ledger échouait après le débit, solde débité SANS trace (débit orphelin). Patch Node =
-- compensation (re-crédit), bon filet mais non transactionnel.
-- Ici : tout dans UNE transaction SQL (verrou FOR UPDATE + débit + ledger) → si le ledger échoue,
-- l'EXCEPTION rollback AUSSI le débit. Plus aucun débit orphelin possible.
--
-- L'idempotence (insert-first sur wallet_idempotency_keys) + la détection d'activité suspecte
-- restent gérées côté backend AVANT l'appel (verrou anti-rejeu déjà en place).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.execute_atomic_withdrawal(
  p_user_id         uuid,
  p_amount          numeric,
  p_description     text DEFAULT 'Retrait',
  p_idempotency_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id   bigint;
  v_balance     numeric;
  v_currency    text;
  v_blocked     boolean;
  v_new_balance numeric;
  v_tx_id       text;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Montant invalide');
  END IF;

  -- Verrou sur l'unique wallet de l'utilisateur (sérialise les débits concurrents)
  SELECT id, balance, currency, COALESCE(is_blocked, false)
    INTO v_wallet_id, v_balance, v_currency, v_blocked
  FROM public.wallets WHERE user_id = p_user_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet introuvable');
  END IF;
  IF v_blocked THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet bloqué');
  END IF;
  IF v_balance < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solde insuffisant');
  END IF;

  v_new_balance := v_balance - p_amount;
  v_tx_id := public.generate_transaction_id();

  -- Débit + ligne d'historique dans la MÊME transaction (atomique : si l'INSERT échoue → rollback du débit)
  UPDATE public.wallets SET balance = v_new_balance, updated_at = now() WHERE id = v_wallet_id;

  INSERT INTO public.wallet_transactions (
    transaction_id, sender_wallet_id, receiver_wallet_id, sender_user_id, receiver_user_id,
    transaction_type, amount, net_amount, status, currency, description, metadata)
  VALUES (
    v_tx_id, v_wallet_id, NULL, p_user_id, NULL,
    'withdrawal', p_amount, p_amount, 'completed', COALESCE(v_currency, 'GNF'), p_description,
    jsonb_build_object('idempotency_key', p_idempotency_key, 'source', 'execute_atomic_withdrawal'));

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id, 'new_balance', v_new_balance);
EXCEPTION WHEN OTHERS THEN
  -- rollback automatique de toute la transaction (débit inclus)
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.execute_atomic_withdrawal(uuid, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_atomic_withdrawal(uuid, numeric, text, text) TO service_role;

SELECT 'execute_atomic_withdrawal créée (débit + ledger atomiques, FOR UPDATE).' AS status;
