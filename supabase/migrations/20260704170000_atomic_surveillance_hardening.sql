-- ============================================================================
-- 🛡️ BLINDAGE ATOMIQUE — surveillance, acquittements, régularisations
-- ----------------------------------------------------------------------------
-- Incident vécu le 04/07/2026 : des régularisations app-side ont ajusté les
-- SOLDES pendant que les TRACES échouaient en silence (enum sans 'credit'/'debit',
-- réponses non vérifiées) → argent bougé sans historique, dénoncé par le gardien
-- untraced_increase. Cette migration rend ces chemins ATOMIQUES côté base :
--
--   1) UNICITÉ DURE de wallet_transactions.transaction_id (0 doublon vérifié sur
--      481 lignes) → toute trace devient idempotente AU NIVEAU BASE.
--   2) apply_wallet_regularization() : trace + solde dans UNE transaction
--      (tout ou rien), idempotente, verrouillée (FOR UPDATE), devise vérifiée,
--      solde jamais négatif. Interdit le split trace/solde pour toujours.
--   3) auto_reconcile_monitor_cases() : la réconciliation automatique en UNE
--      fonction SQL set-based (une transaction, ON CONFLICT DO NOTHING) au lieu
--      de N requêtes applicatives.
--   4) Liste blanche des check_key acquittables (CHECK) sur
--      money_integrity_acknowledged (3 clés existantes vérifiées + untraced_increase).
--
-- Non destructif, rejouable.
-- ============================================================================

-- 1) ── Unicité dure des traces ──────────────────────────────────────────────
CREATE UNIQUE INDEX IF NOT EXISTS uniq_wallet_transactions_transaction_id
  ON public.wallet_transactions (transaction_id)
  WHERE transaction_id IS NOT NULL;

-- 2) ── Régularisation ATOMIQUE : trace + solde = une seule transaction ──────
CREATE OR REPLACE FUNCTION public.apply_wallet_regularization(
  p_transaction_id text,                 -- clé d'idempotence (unique en base)
  p_wallet_id      bigint,
  p_user_id        uuid,
  p_delta          numeric,              -- SIGNÉ : >0 crédit, <0 reprise
  p_currency       text,
  p_description    text,
  p_metadata       jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet      RECORD;
  v_new_balance numeric;
BEGIN
  -- Idempotence dure : la même clé ne s'applique qu'une fois (l'index unique
  -- protège aussi contre la course entre deux appels concurrents).
  IF EXISTS (SELECT 1 FROM public.wallet_transactions WHERE transaction_id = p_transaction_id) THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true, 'transaction_id', p_transaction_id);
  END IF;

  IF p_delta IS NULL OR p_delta = 0 THEN
    RAISE EXCEPTION 'Régularisation refusée : delta nul (%)', p_transaction_id;
  END IF;
  IF p_description IS NULL OR btrim(p_description) = '' THEN
    RAISE EXCEPTION 'Régularisation refusée : description obligatoire (%)', p_transaction_id;
  END IF;

  -- Verrou pessimiste : sérialise avec tout crédit/débit concurrent du wallet.
  SELECT * INTO v_wallet FROM public.wallets
  WHERE id = p_wallet_id AND user_id = p_user_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Wallet % introuvable pour l''utilisateur % (%)', p_wallet_id, p_user_id, p_transaction_id;
  END IF;
  IF COALESCE(v_wallet.currency, 'GNF') <> p_currency THEN
    RAISE EXCEPTION 'Devise % ≠ devise du wallet (%) — conversion à faire AVANT (%)',
      p_currency, COALESCE(v_wallet.currency, 'GNF'), p_transaction_id;
  END IF;
  IF p_delta < 0 AND COALESCE(v_wallet.balance, 0) + p_delta < 0 THEN
    RAISE EXCEPTION 'Reprise refusée : solde % + delta % < 0 (%)',
      COALESCE(v_wallet.balance, 0), p_delta, p_transaction_id;
  END IF;

  UPDATE public.wallets
  SET balance = COALESCE(balance, 0) + p_delta, updated_at = now()
  WHERE id = p_wallet_id
  RETURNING balance INTO v_new_balance;

  -- Trace dans la MÊME transaction : crédit = receiver_*, reprise = sender_*,
  -- montant toujours POSITIF (l'enum transaction_type n'a ni 'credit' ni 'debit').
  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_wallet_id, receiver_user_id, sender_wallet_id, sender_user_id,
    amount, fee, net_amount, currency, transaction_type, status, description, metadata)
  VALUES (
    p_transaction_id,
    CASE WHEN p_delta > 0 THEN p_wallet_id END,
    CASE WHEN p_delta > 0 THEN p_user_id END,
    CASE WHEN p_delta < 0 THEN p_wallet_id END,
    CASE WHEN p_delta < 0 THEN p_user_id END,
    ABS(p_delta), 0, ABS(p_delta), p_currency,
    CASE WHEN p_delta > 0 THEN 'refund' ELSE 'withdrawal' END,
    'completed', p_description,
    COALESCE(p_metadata, '{}'::jsonb)
      || jsonb_build_object('regularization', true, 'delta', p_delta, 'applied_at', now()));

  RETURN jsonb_build_object('success', true, 'transaction_id', p_transaction_id,
    'wallet_id', p_wallet_id, 'delta', p_delta, 'new_balance', v_new_balance);
END;
$$;

REVOKE ALL ON FUNCTION public.apply_wallet_regularization(text, bigint, uuid, numeric, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.apply_wallet_regularization(text, bigint, uuid, numeric, text, text, jsonb) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_wallet_regularization(text, bigint, uuid, numeric, text, text, jsonb) TO service_role;

-- 3) ── Réconciliation automatique ATOMIQUE (set-based, une transaction) ─────
CREATE OR REPLACE FUNCTION public.auto_reconcile_monitor_cases()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fee      int := 0;
  v_untraced int := 0;
BEGIN
  -- a) order_missing_buyer_fee : preuve = trace de régularisation liée à la
  --    commande / son escrow / son numéro (metadata.regularization = true).
  WITH flagged AS (
    SELECT o.id, o.order_number, e.id AS escrow_id
    FROM public.orders o
    JOIN public.escrow_transactions e ON e.order_id = o.id
    WHERE o.created_at > now() - interval '7 days'
      AND o.status <> 'cancelled'
      AND COALESCE(o.total_amount, 0) > 0
      AND NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions wt
        WHERE wt.transaction_type = 'commission'
          AND wt.metadata->>'source' = 'buyer_commission'
          AND wt.metadata->>'order_id' = o.id::text)
  ), proved AS (
    SELECT f.id,
           (SELECT wt.transaction_id FROM public.wallet_transactions wt
            WHERE COALESCE((wt.metadata->>'regularization')::boolean, false)
              AND (wt.metadata->>'order_id'    = f.id::text
                OR wt.metadata->>'escrow_id'   = f.escrow_id::text
                OR wt.metadata->>'order_number' = f.order_number)
            LIMIT 1) AS proof
    FROM flagged f
  )
  INSERT INTO public.money_integrity_acknowledged (check_key, ref_id, reason)
  SELECT 'order_missing_buyer_fee', p.id::text, 'AUTO: régularisation vérifiée (' || p.proof || ')'
  FROM proved p
  WHERE p.proof IS NOT NULL
  ON CONFLICT (check_key, ref_id) DO NOTHING;
  GET DIAGNOSTICS v_fee = ROW_COUNT;

  -- b) untraced_increase : preuve = mouvement documenté après coup (même
  --    utilisateur, même montant ±0,01, fenêtre ±48 h).
  INSERT INTO public.money_integrity_acknowledged (check_key, ref_id, reason)
  SELECT 'untraced_increase', a.id::text,
         'AUTO: mouvement documenté (' || pr.transaction_id || ', ' || pr.amount || ')'
  FROM public.wallet_balance_audit a
  JOIN LATERAL (
    SELECT wt.transaction_id, wt.amount
    FROM public.wallet_transactions wt
    WHERE wt.receiver_user_id = a.user_id
      AND wt.created_at BETWEEN a.changed_at - interval '48 hours'
                            AND a.changed_at + interval '48 hours'
      AND wt.amount BETWEEN a.delta - 0.01 AND a.delta + 0.01
    LIMIT 1
  ) pr ON true
  WHERE a.delta > 0
    AND a.changed_at > now() - interval '7 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions w2
      WHERE w2.receiver_user_id = a.user_id
        AND w2.created_at BETWEEN a.changed_at - interval '10 minutes'
                              AND a.changed_at + interval '10 minutes')
  ON CONFLICT (check_key, ref_id) DO NOTHING;
  GET DIAGNOSTICS v_untraced = ROW_COUNT;

  RETURN jsonb_build_object('success', true, 'acked_missing_fee', v_fee,
    'acked_untraced', v_untraced, 'generated_at', now());
END;
$$;

REVOKE ALL ON FUNCTION public.auto_reconcile_monitor_cases() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.auto_reconcile_monitor_cases() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auto_reconcile_monitor_cases() TO service_role;

-- 4) ── Liste blanche des contrôles acquittables ─────────────────────────────
-- (clés existantes vérifiées en base : escrow_released_no_commission,
--  escrow_released_zero_credit, order_missing_buyer_fee — + untraced_increase)
ALTER TABLE public.money_integrity_acknowledged
  DROP CONSTRAINT IF EXISTS mia_check_key_whitelist;
ALTER TABLE public.money_integrity_acknowledged
  ADD CONSTRAINT mia_check_key_whitelist CHECK (check_key IN (
    'order_missing_buyer_fee',
    'untraced_increase',
    'escrow_released_zero_credit',
    'escrow_released_no_commission'
  ));

-- 5) ── Vérification ─────────────────────────────────────────────────────────
SELECT
  CASE WHEN EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uniq_wallet_transactions_transaction_id')
    THEN '✅ unicité transaction_id' ELSE '❌ index unique absent' END AS unicite,
  CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'apply_wallet_regularization')
    THEN '✅ régularisation atomique' ELSE '❌ apply_wallet_regularization absente' END AS regularisation,
  CASE WHEN EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'auto_reconcile_monitor_cases')
    THEN '✅ réconciliation atomique' ELSE '❌ auto_reconcile_monitor_cases absente' END AS reconciliation,
  CASE WHEN EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'mia_check_key_whitelist')
    THEN '✅ liste blanche acquittements' ELSE '❌ contrainte whitelist absente' END AS whitelist;
