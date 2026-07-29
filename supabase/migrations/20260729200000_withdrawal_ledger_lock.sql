-- ============================================================================
-- VERROU RETRAITS (miroir du verrou dépôts) — aucun débit sans payout adossé + revert atomique
-- ----------------------------------------------------------------------------
-- Invariant : l'argent ne quitte JAMAIS un wallet « dans le vide ». Un retrait DÉBITE vers un
-- état `pending` traçable (immobilisé, pas détruit) ; il ne devient `paid` que sur confirmation
-- d'un vrai versement ; si le payout échoue/refuse, le montant est REMBOURSÉ atomiquement.
-- Machine à états stricte : pending → processing → paid  |  pending/processing/failed → refunded.
-- Jamais paid → refunded. Jamais double débit (idempotency_key UNIQUE) ni double payout
-- (payout_reference UNIQUE). Transitions réservées à service_role (backend/webhook Node).
-- ============================================================================

-- 1) Ledger canonique des retraits
CREATE TABLE IF NOT EXISTS public.withdrawals (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL,
  wallet_id         bigint,
  amount            numeric NOT NULL CHECK (amount > 0),
  fee               numeric NOT NULL DEFAULT 0 CHECK (fee >= 0),
  currency          text NOT NULL DEFAULT 'GNF',
  destination_type  text NOT NULL DEFAULT 'momo',          -- 'momo' | 'card' | 'bank' | 'agent'
  destination       jsonb DEFAULT '{}'::jsonb,
  status            text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','processing','paid','refunded','failed')),
  payout_provider   text,
  payout_reference  text,                                   -- réf prestataire (un payout = une fois)
  idempotency_key   text NOT NULL,                          -- anti double-débit
  failure_reason    text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  paid_at           timestamptz,
  refunded_at       timestamptz,
  CONSTRAINT withdrawals_idem_uk UNIQUE (idempotency_key),
  CONSTRAINT withdrawals_payout_ref_uk UNIQUE (payout_reference)
);
CREATE INDEX IF NOT EXISTS idx_withdrawals_user ON public.withdrawals(user_id);
CREATE INDEX IF NOT EXISTS idx_withdrawals_status ON public.withdrawals(status)
  WHERE status IN ('pending','processing');

ALTER TABLE public.withdrawals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS w_owner_read ON public.withdrawals;
CREATE POLICY w_owner_read ON public.withdrawals FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS w_admin_read ON public.withdrawals;
CREATE POLICY w_admin_read ON public.withdrawals FOR SELECT TO authenticated USING (public.is_admin_or_pdg());

-- 2) DEMANDE de retrait : débit → état pending, dans UNE transaction. Idempotent.
CREATE OR REPLACE FUNCTION public.request_withdrawal(
  p_user_id uuid, p_amount numeric, p_currency text DEFAULT 'GNF',
  p_destination_type text DEFAULT 'momo', p_destination jsonb DEFAULT '{}'::jsonb,
  p_idempotency_key text DEFAULT NULL, p_fee numeric DEFAULT 0, p_description text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_existing record;
  v_wallet   record;
  v_total    numeric;
  v_wid      uuid;
  v_tx_id    text;
BEGIN
  IF p_user_id IS NULL OR COALESCE(p_amount,0) <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'MONTANT_INVALIDE');
  END IF;
  IF p_idempotency_key IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'IDEMPOTENCY_KEY_REQUISE');
  END IF;

  -- Idempotence : même clé → on renvoie la demande existante, JAMAIS un 2e débit.
  SELECT * INTO v_existing FROM public.withdrawals WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true,
      'withdrawal_id', v_existing.id, 'status', v_existing.status);
  END IF;

  v_total := p_amount + COALESCE(p_fee, 0);

  -- Verrou wallet + solde suffisant AVANT tout débit.
  SELECT id, balance, currency INTO v_wallet
  FROM public.wallets
  WHERE user_id = p_user_id
  ORDER BY (currency = p_currency) DESC, id ASC
  LIMIT 1 FOR UPDATE;
  IF v_wallet.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'WALLET_INTROUVABLE');
  END IF;
  IF COALESCE(v_wallet.balance,0) < v_total THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solde insuffisant', 'error_code', 'INSUFFICIENT_BALANCE');
  END IF;

  -- Débit → l'argent quitte le solde disponible, immobilisé dans la demande pending.
  UPDATE public.wallets SET balance = balance - v_total, updated_at = now() WHERE id = v_wallet.id;

  INSERT INTO public.withdrawals (user_id, wallet_id, amount, fee, currency, destination_type,
                                  destination, status, idempotency_key)
  VALUES (p_user_id, v_wallet.id, p_amount, COALESCE(p_fee,0), COALESCE(p_currency, v_wallet.currency),
          p_destination_type, COALESCE(p_destination,'{}'::jsonb), 'pending', p_idempotency_key)
  RETURNING id INTO v_wid;

  v_tx_id := public.generate_transaction_id();
  INSERT INTO public.wallet_transactions (
    transaction_id, sender_wallet_id, sender_user_id, transaction_type, amount, fee, net_amount,
    status, currency, description, reference_id, metadata)
  VALUES (
    v_tx_id, v_wallet.id, p_user_id, 'withdrawal', p_amount, COALESCE(p_fee,0), v_total,
    'pending', COALESCE(p_currency, v_wallet.currency), COALESCE(p_description, 'Retrait (en attente de versement)'),
    v_wid::text, jsonb_build_object('withdrawal_id', v_wid, 'destination_type', p_destination_type));

  RETURN jsonb_build_object('success', true, 'withdrawal_id', v_wid, 'status', 'pending', 'debited', v_total);
END;
$function$;

-- 3) Le payout a été ACCEPTÉ par le prestataire → processing (étape intermédiaire optionnelle).
CREATE OR REPLACE FUNCTION public.mark_withdrawal_processing(p_withdrawal_id uuid, p_provider text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_w record;
BEGIN
  SELECT * INTO v_w FROM public.withdrawals WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'WITHDRAWAL_INTROUVABLE'; END IF;
  IF v_w.status = 'processing' THEN RETURN jsonb_build_object('success', true, 'idempotent', true); END IF;
  IF v_w.status <> 'pending' THEN
    RAISE EXCEPTION 'TRANSITION_INVALIDE' USING DETAIL = 'processing depuis ' || v_w.status;
  END IF;
  UPDATE public.withdrawals SET status='processing', payout_provider=p_provider, updated_at=now()
   WHERE id = p_withdrawal_id;
  RETURN jsonb_build_object('success', true, 'status', 'processing');
END;
$function$;

-- 4) Payout CONFIRMÉ payé → débit rendu définitif. payout_reference UNIQUE = un seul payout.
CREATE OR REPLACE FUNCTION public.mark_withdrawal_paid(p_withdrawal_id uuid, p_payout_reference text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_w record;
BEGIN
  SELECT * INTO v_w FROM public.withdrawals WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'WITHDRAWAL_INTROUVABLE'; END IF;
  -- Rejeu de la même confirmation → no-op idempotent.
  IF v_w.status = 'paid' THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true, 'status', 'paid');
  END IF;
  -- Interdit de « payer » un retrait déjà remboursé / échoué (machine à états stricte).
  IF v_w.status NOT IN ('pending','processing') THEN
    RAISE EXCEPTION 'TRANSITION_INVALIDE' USING DETAIL = 'paid depuis ' || v_w.status;
  END IF;
  UPDATE public.withdrawals
     SET status='paid', payout_reference=p_payout_reference, paid_at=now(), updated_at=now()
   WHERE id = p_withdrawal_id;
  UPDATE public.wallet_transactions SET status='completed', updated_at=now()
   WHERE reference_id = p_withdrawal_id::text AND transaction_type='withdrawal' AND status='pending';
  RETURN jsonb_build_object('success', true, 'status', 'paid');
END;
$function$;

-- 5) Payout REFUSÉ/échec/timeout → REMBOURSEMENT ATOMIQUE (l'argent revient au solde).
CREATE OR REPLACE FUNCTION public.refund_withdrawal(p_withdrawal_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_w record; v_total numeric; v_tx_id text;
BEGIN
  SELECT * INTO v_w FROM public.withdrawals WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'WITHDRAWAL_INTROUVABLE'; END IF;
  -- Déjà remboursé → no-op idempotent (pas de double crédit).
  IF v_w.status = 'refunded' THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true, 'status', 'refunded');
  END IF;
  -- Interdit de rembourser un retrait déjà payé (argent réellement parti).
  IF v_w.status = 'paid' THEN
    RAISE EXCEPTION 'CANNOT_REFUND_PAID' USING DETAIL = 'retrait déjà versé';
  END IF;

  v_total := v_w.amount + COALESCE(v_w.fee, 0);
  UPDATE public.wallets SET balance = COALESCE(balance,0) + v_total, updated_at = now()
   WHERE id = v_w.wallet_id;

  UPDATE public.withdrawals
     SET status='refunded', refunded_at=now(), failure_reason=COALESCE(p_reason, failure_reason), updated_at=now()
   WHERE id = p_withdrawal_id;

  -- La ligne de retrait pending devient 'failed' ; on trace le remboursement.
  UPDATE public.wallet_transactions SET status='failed', updated_at=now()
   WHERE reference_id = p_withdrawal_id::text AND transaction_type='withdrawal' AND status='pending';
  v_tx_id := public.generate_transaction_id();
  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_wallet_id, receiver_user_id, transaction_type, amount, net_amount,
    status, currency, description, reference_id, metadata)
  VALUES (
    v_tx_id, v_w.wallet_id, v_w.user_id, 'refund', v_total, v_total, 'completed', v_w.currency,
    'Retrait annulé — fonds restitués. ' || COALESCE(p_reason,''), p_withdrawal_id::text,
    jsonb_build_object('withdrawal_id', p_withdrawal_id, 'refund', true));

  RETURN jsonb_build_object('success', true, 'status', 'refunded', 'restored', v_total);
END;
$function$;

-- 6) GRANTs : transitions financières réservées à service_role (backend/webhook Node).
REVOKE ALL ON FUNCTION public.request_withdrawal(uuid, numeric, text, text, jsonb, text, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.request_withdrawal(uuid, numeric, text, text, jsonb, text, numeric, text) TO service_role;
REVOKE ALL ON FUNCTION public.mark_withdrawal_processing(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mark_withdrawal_processing(uuid, text) TO service_role;
REVOKE ALL ON FUNCTION public.mark_withdrawal_paid(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mark_withdrawal_paid(uuid, text) TO service_role;
REVOKE ALL ON FUNCTION public.refund_withdrawal(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.refund_withdrawal(uuid, text) TO service_role;

-- 7) Durcissement : les primitives de DÉBIT nu ne doivent PAS être appelables via PostgREST
--    (mêmes raisons que côté dépôts : SECURITY DEFINER sans contrôle du caller). Le backend
--    appelle en service_role. Vérifié : aucun appel frontend direct.
REVOKE ALL ON FUNCTION public.execute_atomic_withdrawal(uuid, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.execute_atomic_withdrawal(uuid, numeric, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.agent_cash_withdrawal(uuid, uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.agent_cash_withdrawal(uuid, uuid, numeric, text) TO service_role;
