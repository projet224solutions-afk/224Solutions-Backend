-- ============================================================================
-- 🛡️ DÉPÔT ATOMIQUE — RPC execute_atomic_deposit (crédit AML + ledger en 1 transaction).
--
-- Avant : creditWallet (Node) appelait credit_user_wallet_safe (crédit+plafond AML) PUIS
-- INSERT ledger en 2 appels séparés → si le ledger échouait après le crédit, solde crédité
-- SANS trace (crédit orphelin, juste loggué). Détecté par le watchdog untraced_increase mais
-- non prévenu.
-- Ici : credit_user_wallet_safe + INSERT ledger dans UNE transaction SQL → si le ledger échoue,
-- l'EXCEPTION rollback AUSSI le crédit (et son enregistrement d'idempotence). Plus de crédit orphelin.
--
-- L'idempotence est double-couche : credit_user_wallet_safe l'assure par (source_type, source_txn_id) ;
-- si déjà crédité (skipped/idempotent) → on N'insère PAS un nouveau ledger (anti double-ligne).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.execute_atomic_deposit(
  p_user_id     uuid,
  p_amount      numeric,
  p_description text DEFAULT 'Dépôt',
  p_reference   text DEFAULT NULL,
  p_source_type text DEFAULT 'deposit'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res       jsonb;
  v_credited  numeric;
  v_quar      numeric;
  v_wallet_id bigint;
  v_cur       text;
  v_tx_id     text;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Montant invalide');
  END IF;

  -- Crédit + plafond/quarantaine AML (idempotent par source_txn_id), DANS cette transaction.
  v_res := public.credit_user_wallet_safe(p_user_id, p_amount, NULL, p_source_type, p_reference);

  -- Déjà crédité (idempotent) ou rien crédité → pas de nouvelle ligne d'historique.
  IF COALESCE((v_res->>'skipped')::boolean, false) THEN
    RETURN jsonb_build_object('success', true, 'skipped', true,
      'credited', COALESCE((v_res->>'credited')::numeric, 0),
      'wallet_id', (v_res->>'wallet_id'), 'currency', v_res->>'currency');
  END IF;

  v_credited  := COALESCE((v_res->>'credited')::numeric, 0);
  v_quar      := COALESCE((v_res->>'quarantined')::numeric, 0);
  v_wallet_id := (v_res->>'wallet_id')::bigint;
  v_cur       := COALESCE(v_res->>'currency', 'GNF');
  v_tx_id     := public.generate_transaction_id();

  -- Ledger dans la MÊME transaction (si échec → rollback du crédit ci-dessus).
  INSERT INTO public.wallet_transactions (
    transaction_id, sender_wallet_id, receiver_wallet_id, sender_user_id, receiver_user_id,
    transaction_type, amount, net_amount, status, currency, description, metadata)
  VALUES (
    v_tx_id, NULL, v_wallet_id, NULL, p_user_id,
    p_source_type, p_amount, v_credited, 'completed', v_cur, p_description,
    jsonb_build_object('reference', p_reference, 'source', 'execute_atomic_deposit', 'quarantined', v_quar));

  RETURN jsonb_build_object('success', true, 'credited', v_credited, 'quarantined', v_quar,
    'wallet_id', v_wallet_id, 'currency', v_cur, 'transaction_id', v_tx_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.execute_atomic_deposit(uuid, numeric, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_atomic_deposit(uuid, numeric, text, text, text) TO service_role;

SELECT 'execute_atomic_deposit créée (crédit AML + ledger atomiques).' AS status;
