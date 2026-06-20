-- 🔁 TRANSFERTS WALLET ATOMIQUES — corrige 2 bugs + ajoute le FX.
--
-- BUG CRITIQUE corrigé : l'RPC execute_atomic_wallet_transfer insérait dans
-- enhanced_transactions une colonne `transaction_type` QUI N'EXISTE PAS → le RPC échouait
-- TOUJOURS → même les transferts same-currency tombaient dans le chemin manuel NON-atomique.
-- Correctif : `transaction_type` déplacé dans `metadata` (jsonb).
--
-- AJOUT : execute_atomic_wallet_transfer_fx pour les transferts INTER-DEVISES (débit≠crédit),
-- atomiques en 1 transaction (avant : chemin manuel avec revert non vérifié = risque de perte).

-- Supprime la surcharge morte (wallet_id uuid) : wallets.id est bigint donc elle n'est
-- jamais appelée, et elle gardait l'ancien INSERT cassé + créait une ambiguïté.
DROP FUNCTION IF EXISTS public.execute_atomic_wallet_transfer(uuid, uuid, numeric, text, uuid, uuid, numeric, numeric);

-- ── same-currency (corrigé) ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.execute_atomic_wallet_transfer(
  p_sender_id uuid, p_receiver_id uuid, p_amount numeric, p_description text,
  p_sender_wallet_id bigint, p_recipient_wallet_id bigint,
  p_sender_balance_before numeric, p_recipient_balance_before numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_tx_id uuid := gen_random_uuid();
BEGIN
  UPDATE wallets SET balance = p_sender_balance_before - p_amount, updated_at = now()
  WHERE id = p_sender_wallet_id AND balance = p_sender_balance_before;
  IF NOT FOUND THEN RAISE EXCEPTION 'Concurrent modification detected'; END IF;

  UPDATE wallets SET balance = p_recipient_balance_before + p_amount, updated_at = now()
  WHERE id = p_recipient_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Recipient wallet not found'; END IF;

  INSERT INTO enhanced_transactions (id, sender_id, receiver_id, amount, method, status, currency, metadata)
  VALUES (
    v_tx_id, p_sender_id, p_receiver_id, p_amount, 'wallet', 'completed',
    (SELECT currency FROM wallets WHERE id = p_sender_wallet_id LIMIT 1),
    jsonb_build_object('description', p_description, 'atomic', true, 'transaction_type', 'transfer')
  );

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id);
END;
$function$;

-- ── inter-devises (FX) ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.execute_atomic_wallet_transfer_fx(
  p_sender_id uuid, p_receiver_id uuid, p_debit_amount numeric, p_credit_amount numeric,
  p_description text, p_sender_wallet_id bigint, p_recipient_wallet_id bigint,
  p_sender_balance_before numeric, p_recipient_balance_before numeric,
  p_sender_currency text, p_receiver_currency text, p_rate_used numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_tx_id uuid := gen_random_uuid();
BEGIN
  IF p_debit_amount <= 0 OR p_credit_amount <= 0 THEN RAISE EXCEPTION 'Montants invalides'; END IF;

  UPDATE wallets SET balance = p_sender_balance_before - p_debit_amount, updated_at = now()
  WHERE id = p_sender_wallet_id AND balance = p_sender_balance_before;
  IF NOT FOUND THEN RAISE EXCEPTION 'Concurrent modification detected'; END IF;

  UPDATE wallets SET balance = p_recipient_balance_before + p_credit_amount, updated_at = now()
  WHERE id = p_recipient_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Recipient wallet not found'; END IF;

  INSERT INTO enhanced_transactions (id, sender_id, receiver_id, amount, method, status, currency, metadata)
  VALUES (
    v_tx_id, p_sender_id, p_receiver_id, p_debit_amount, 'wallet', 'completed', p_sender_currency,
    jsonb_build_object(
      'description', p_description, 'atomic', true, 'fx', true, 'transaction_type', 'transfer',
      'credit_amount', p_credit_amount, 'sender_currency', p_sender_currency,
      'receiver_currency', p_receiver_currency, 'rate_used', p_rate_used
    )
  );

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.execute_atomic_wallet_transfer(uuid, uuid, numeric, text, bigint, bigint, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.execute_atomic_wallet_transfer(uuid, uuid, numeric, text, bigint, bigint, numeric, numeric) TO service_role;
REVOKE ALL ON FUNCTION public.execute_atomic_wallet_transfer_fx(uuid, uuid, numeric, numeric, text, bigint, bigint, numeric, numeric, text, text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.execute_atomic_wallet_transfer_fx(uuid, uuid, numeric, numeric, text, bigint, bigint, numeric, numeric, text, text, numeric) TO service_role;
