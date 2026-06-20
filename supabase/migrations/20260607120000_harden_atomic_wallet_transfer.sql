-- 🛡️ DURCISSEMENT ATOMIQUE DES TRANSFERTS WALLET (same-currency + FX international)
--
-- Corrige 3 faiblesses de robustesse des RPC execute_atomic_wallet_transfer[_fx] :
--   1. AUCUNE garde de solde DANS la transaction (le WHERE balance = before détecte la
--      concurrence mais ne garantit pas balance >= montant → risque de solde NÉGATIF).
--   2. Concurrence purement optimiste, sans verrou de ligne → échecs sporadiques sous
--      charge et pas de re-vérification de is_blocked dans la transaction.
--   3. La commission FX était débitée de l'expéditeur mais CRÉDITÉE NULLE PART (perdue,
--      non auditable). Elle est désormais inscrite atomiquement dans platform_fx_commissions.
--
-- Stratégie : verrou explicite SELECT ... FOR UPDATE (ordre déterministe par id pour éviter
-- les deadlocks), re-lecture AUTORITAIRE du solde après verrou, gardes solde/blocage, puis
-- débit/crédit + registre commission — le tout dans la transaction implicite de la fonction.

-- ── Registre des commissions FX (audit + « la plateforme garde les 5% ») ──────────
CREATE TABLE IF NOT EXISTS public.platform_fx_commissions (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id  uuid,
  sender_id       uuid,
  receiver_id     uuid,
  amount          numeric     NOT NULL,
  currency        text        NOT NULL,
  rate_used       numeric,
  created_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.platform_fx_commissions ENABLE ROW LEVEL SECURITY;
-- Accès uniquement via service_role (backend Node.js) qui bypass la RLS. Aucune policy publique.
CREATE INDEX IF NOT EXISTS platform_fx_commissions_created_idx ON public.platform_fx_commissions (created_at);
CREATE INDEX IF NOT EXISTS platform_fx_commissions_tx_idx      ON public.platform_fx_commissions (transaction_id);

-- Supprime la surcharge morte (wallet_id uuid) de l'ancien schéma, pour éviter toute
-- ambiguïté d'overload (auto-suffisant même si 20260606140000 n'a jamais été appliquée).
DROP FUNCTION IF EXISTS public.execute_atomic_wallet_transfer(uuid, uuid, numeric, text, uuid, uuid, numeric, numeric);

-- ── same-currency (durci : verrou + gardes) ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.execute_atomic_wallet_transfer(
  p_sender_id uuid, p_receiver_id uuid, p_amount numeric, p_description text,
  p_sender_wallet_id bigint, p_recipient_wallet_id bigint,
  p_sender_balance_before numeric, p_recipient_balance_before numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_tx_id uuid := gen_random_uuid();
  v_sender_balance numeric;
  v_recipient_balance numeric;
  v_sender_blocked boolean;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Montant invalide'; END IF;

  -- Verrou déterministe (ordre par id) pour sérialiser et éviter les deadlocks.
  IF p_sender_wallet_id <= p_recipient_wallet_id THEN
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
  ELSE
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
  END IF;

  SELECT balance, COALESCE(is_blocked, false) INTO v_sender_balance, v_sender_blocked
  FROM wallets WHERE id = p_sender_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sender wallet not found'; END IF;
  IF v_sender_blocked THEN RAISE EXCEPTION 'Sender wallet blocked'; END IF;

  SELECT balance INTO v_recipient_balance FROM wallets WHERE id = p_recipient_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Recipient wallet not found'; END IF;

  IF v_sender_balance < p_amount THEN RAISE EXCEPTION 'Solde insuffisant'; END IF;

  UPDATE wallets SET balance = v_sender_balance - p_amount, updated_at = now() WHERE id = p_sender_wallet_id;
  UPDATE wallets SET balance = v_recipient_balance + p_amount, updated_at = now() WHERE id = p_recipient_wallet_id;

  INSERT INTO enhanced_transactions (id, sender_id, receiver_id, amount, method, status, currency, metadata)
  VALUES (
    v_tx_id, p_sender_id, p_receiver_id, p_amount, 'wallet', 'completed',
    (SELECT currency FROM wallets WHERE id = p_sender_wallet_id LIMIT 1),
    jsonb_build_object('description', p_description, 'atomic', true, 'transaction_type', 'transfer')
  );

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id);
END;
$function$;

-- ── inter-devises (FX) durci : verrou + gardes + registre commission ───────────────
-- On DROP l'ancienne signature (12 args) pour la remplacer par la nouvelle (13 args avec
-- p_fee_amount). DEFAULT 0 → tolère un appel à 12 args, mais on évite l'ambiguïté d'overload.
DROP FUNCTION IF EXISTS public.execute_atomic_wallet_transfer_fx(uuid, uuid, numeric, numeric, text, bigint, bigint, numeric, numeric, text, text, numeric);

CREATE OR REPLACE FUNCTION public.execute_atomic_wallet_transfer_fx(
  p_sender_id uuid, p_receiver_id uuid, p_debit_amount numeric, p_credit_amount numeric,
  p_description text, p_sender_wallet_id bigint, p_recipient_wallet_id bigint,
  p_sender_balance_before numeric, p_recipient_balance_before numeric,
  p_sender_currency text, p_receiver_currency text, p_rate_used numeric,
  p_fee_amount numeric DEFAULT 0
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_tx_id uuid := gen_random_uuid();
  v_sender_balance numeric;
  v_recipient_balance numeric;
  v_sender_blocked boolean;
  v_fee numeric := COALESCE(p_fee_amount, 0);
BEGIN
  IF p_debit_amount IS NULL OR p_debit_amount <= 0 THEN RAISE EXCEPTION 'Montants invalides'; END IF;
  IF p_credit_amount IS NULL OR p_credit_amount <= 0 THEN RAISE EXCEPTION 'Montants invalides'; END IF;
  IF v_fee < 0 THEN RAISE EXCEPTION 'Commission invalide'; END IF;

  -- Verrou déterministe (ordre par id) pour sérialiser et éviter les deadlocks.
  IF p_sender_wallet_id <= p_recipient_wallet_id THEN
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
  ELSE
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
  END IF;

  -- Re-lecture AUTORITAIRE des soldes APRÈS verrou (on n'utilise plus les *_before périmés).
  SELECT balance, COALESCE(is_blocked, false) INTO v_sender_balance, v_sender_blocked
  FROM wallets WHERE id = p_sender_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sender wallet not found'; END IF;
  IF v_sender_blocked THEN RAISE EXCEPTION 'Sender wallet blocked'; END IF;

  SELECT balance INTO v_recipient_balance FROM wallets WHERE id = p_recipient_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Recipient wallet not found'; END IF;

  -- Garde de solde DANS la transaction (p_debit_amount = montant + commission).
  IF v_sender_balance < p_debit_amount THEN RAISE EXCEPTION 'Solde insuffisant'; END IF;

  UPDATE wallets SET balance = v_sender_balance - p_debit_amount, updated_at = now() WHERE id = p_sender_wallet_id;
  UPDATE wallets SET balance = v_recipient_balance + p_credit_amount, updated_at = now() WHERE id = p_recipient_wallet_id;

  INSERT INTO enhanced_transactions (id, sender_id, receiver_id, amount, method, status, currency, metadata)
  VALUES (
    v_tx_id, p_sender_id, p_receiver_id, p_debit_amount, 'wallet', 'completed', p_sender_currency,
    jsonb_build_object(
      'description', p_description, 'atomic', true, 'fx', true, 'transaction_type', 'transfer',
      'amount_sent', (p_debit_amount - v_fee), 'amount_received', p_credit_amount, 'credit_amount', p_credit_amount,
      'fee_amount', v_fee, 'sender_currency', p_sender_currency,
      'receiver_currency', p_receiver_currency, 'rate_used', p_rate_used
    )
  );

  -- La plateforme GARDE la commission : inscription atomique dans le registre (audit PDG).
  IF v_fee > 0 THEN
    INSERT INTO platform_fx_commissions (transaction_id, sender_id, receiver_id, amount, currency, rate_used)
    VALUES (v_tx_id, p_sender_id, p_receiver_id, v_fee, p_sender_currency, p_rate_used);
  END IF;

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id);
END;
$function$;

-- ── Grants (service_role uniquement) ──────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.execute_atomic_wallet_transfer(uuid, uuid, numeric, text, bigint, bigint, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.execute_atomic_wallet_transfer(uuid, uuid, numeric, text, bigint, bigint, numeric, numeric) TO service_role;
REVOKE ALL ON FUNCTION public.execute_atomic_wallet_transfer_fx(uuid, uuid, numeric, numeric, text, bigint, bigint, numeric, numeric, text, text, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.execute_atomic_wallet_transfer_fx(uuid, uuid, numeric, numeric, text, bigint, bigint, numeric, numeric, text, text, numeric, numeric) TO service_role;
