-- ============================================================================
-- 🛡️ DURCISSEMENT ATOMIQUE — crédit wallet (escrow/commission/remboursement/re-crédit).
-- ----------------------------------------------------------------------------
-- Audit wallet vendeur : le flux escrow→wallet+conversion est correct, mais le CRÉDIT
-- n'était PAS idempotent → un retry backend ou un re-crédit manuel pouvait DOUBLER l'argent.
-- On rend `credit_user_wallet_safe` idempotent par (source_type, source_txn_id) :
--   • verrou wallet FOR UPDATE = sérialise par utilisateur (déjà présent),
--   • après le verrou : si la source a déjà été créditée → on ne refait RIEN,
--   • sinon on convertit + crédite (AML inchangé) + on ENREGISTRE la source (anti-rejeu).
-- + release_escrow_to_seller passe désormais des clés de source (escrow_release / escrow_commission)
--   → double-crédit impossible même hors du garde de statut escrow (défense en profondeur).
-- + surveillance : money_integrity_report détecte les libérations créditées à 0 (quarantine bloquée).
-- Idempotent, REVOKE FROM PUBLIC, signatures INCHANGÉES (zéro nouvelle surcharge).
-- ============================================================================

-- 1) ── Registre d'idempotence des crédits ───────────────────────────────────
CREATE TABLE IF NOT EXISTS public.wallet_credit_idempotency (
  source_type   text NOT NULL,
  source_txn_id text NOT NULL,
  user_id       uuid NOT NULL,
  credited      numeric,
  currency      text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source_type, source_txn_id)
);
ALTER TABLE public.wallet_credit_idempotency ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS wci_admin_read ON public.wallet_credit_idempotency;
CREATE POLICY wci_admin_read ON public.wallet_credit_idempotency FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());

-- 2) ── credit_user_wallet_safe : conversion (inchangée) + IDEMPOTENCE ────────
CREATE OR REPLACE FUNCTION public.credit_user_wallet_safe(
  p_user_id       uuid,
  p_amount        numeric,
  p_from_currency text DEFAULT NULL,
  p_source_type   text DEFAULT NULL,
  p_source_txn_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id  bigint;
  v_wallet_cur text;
  v_bal        numeric;
  v_rate       numeric;
  v_credit     numeric;
  v_credited   numeric;
  v_q_amt      numeric := 0;
  v_from_usd   numeric;
  v_usd_to     numeric;
BEGIN
  IF p_user_id IS NULL OR COALESCE(p_amount, 0) <= 0 THEN
    RETURN jsonb_build_object('credited', 0, 'currency', p_from_currency, 'skipped', true);
  END IF;

  -- Verrou wallet : sérialise tous les crédits de CET utilisateur (idempotence sûre ci-dessous).
  SELECT id, currency, balance INTO v_wallet_id, v_wallet_cur, v_bal
  FROM public.wallets
  WHERE user_id = p_user_id
  ORDER BY (currency = p_from_currency) DESC, id ASC
  LIMIT 1 FOR UPDATE;

  IF v_wallet_id IS NULL THEN
    INSERT INTO public.wallets (user_id, balance, currency, wallet_status)
    VALUES (p_user_id, 0, COALESCE(p_from_currency, 'GNF'), 'active')
    RETURNING id, currency, balance INTO v_wallet_id, v_wallet_cur, v_bal;
  END IF;

  -- ── IDEMPOTENCE : crédit déjà appliqué pour cette source → ne rien refaire ──
  IF p_source_type IS NOT NULL AND p_source_txn_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.wallet_credit_idempotency
                 WHERE source_type = p_source_type AND source_txn_id = p_source_txn_id) THEN
    RETURN jsonb_build_object('credited', 0, 'currency', v_wallet_cur, 'wallet_id', v_wallet_id,
      'idempotent', true, 'skipped', true);
  END IF;

  -- ── Conversion vers la devise du wallet (directe/inverse, sinon cross USD) ──
  IF p_from_currency IS NULL OR v_wallet_cur = p_from_currency THEN
    v_credit := p_amount;
  ELSE
    SELECT CASE WHEN cer.from_currency = p_from_currency THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END
    INTO v_rate
    FROM public.currency_exchange_rates cer
    WHERE ((cer.from_currency = p_from_currency AND cer.to_currency = v_wallet_cur)
        OR (cer.from_currency = v_wallet_cur AND cer.to_currency = p_from_currency))
      AND cer.is_active = true
    ORDER BY cer.retrieved_at DESC LIMIT 1;

    IF v_rate IS NULL OR v_rate <= 0 THEN
      SELECT CASE WHEN cer.from_currency = p_from_currency THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END
      INTO v_from_usd FROM public.currency_exchange_rates cer
      WHERE ((cer.from_currency = p_from_currency AND cer.to_currency = 'USD')
          OR (cer.from_currency = 'USD' AND cer.to_currency = p_from_currency))
        AND cer.is_active = true ORDER BY cer.retrieved_at DESC LIMIT 1;
      SELECT CASE WHEN cer.from_currency = 'USD' THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END
      INTO v_usd_to FROM public.currency_exchange_rates cer
      WHERE ((cer.from_currency = 'USD' AND cer.to_currency = v_wallet_cur)
          OR (cer.from_currency = v_wallet_cur AND cer.to_currency = 'USD'))
        AND cer.is_active = true ORDER BY cer.retrieved_at DESC LIMIT 1;
      IF v_from_usd IS NOT NULL AND v_from_usd > 0 AND v_usd_to IS NOT NULL AND v_usd_to > 0 THEN
        v_rate := v_from_usd * v_usd_to;
      END IF;
    END IF;

    IF v_rate IS NULL OR v_rate <= 0 THEN
      RAISE EXCEPTION 'FX_RATE_MISSING: taux introuvable % → % (crédit refusé)', p_from_currency, v_wallet_cur;
    END IF;
    v_credit := ROUND(p_amount * v_rate, 2);
  END IF;

  -- ── Plafond + quarantaine AML (résilient au drift) ──
  BEGIN
    v_credited := public.apply_wallet_cap_split(p_user_id, v_wallet_id, COALESCE(v_bal, 0), v_credit, v_wallet_cur, p_source_type, p_source_txn_id);
  EXCEPTION WHEN undefined_function THEN
    v_credited := v_credit;
  END;
  v_q_amt := v_credit - v_credited;

  IF v_credited > 0 THEN
    UPDATE public.wallets SET balance = COALESCE(balance, 0) + v_credited, updated_at = now() WHERE id = v_wallet_id;
  END IF;

  -- ── Marque la source comme traitée (anti double-crédit sur rejeu) ──
  IF p_source_type IS NOT NULL AND p_source_txn_id IS NOT NULL THEN
    INSERT INTO public.wallet_credit_idempotency (source_type, source_txn_id, user_id, credited, currency)
    VALUES (p_source_type, p_source_txn_id, p_user_id, v_credited, v_wallet_cur)
    ON CONFLICT (source_type, source_txn_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('credited', v_credited, 'currency', v_wallet_cur, 'wallet_id', v_wallet_id,
    'quarantined', v_q_amt, 'capped', (v_q_amt > 0));
END;
$$;
REVOKE ALL ON FUNCTION public.credit_user_wallet_safe(uuid, numeric, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_user_wallet_safe(uuid, numeric, text, text, text) TO authenticated, service_role;

-- 3) ── release_escrow_to_seller : crédits avec CLÉS DE SOURCE (double-proof) ──
CREATE OR REPLACE FUNCTION public.release_escrow_to_seller(
  p_escrow_id uuid,
  p_reason    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_escrow        RECORD;
  v_commission    numeric;
  v_vendor_amount numeric;
  v_cur           text;
  v_seller        uuid;
  v_pdg           uuid;
  v_seller_res    jsonb;
  v_wallet_id     bigint;
BEGIN
  SELECT * INTO v_escrow FROM public.escrow_transactions WHERE id = p_escrow_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Escrow introuvable');
  END IF;
  IF v_escrow.status NOT IN ('pending', 'held') THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'status', v_escrow.status);
  END IF;

  v_cur    := COALESCE(v_escrow.currency, 'GNF');
  v_seller := COALESCE(v_escrow.receiver_id, v_escrow.seller_id);
  IF v_seller IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendeur manquant sur l''escrow');
  END IF;
  v_commission    := COALESCE(NULLIF(v_escrow.commission_amount, 0), v_escrow.amount * 0.025);
  v_vendor_amount := v_escrow.amount - v_commission;

  -- Crédit vendeur (net) + commission PDG, CONVERTIS + IDEMPOTENTS (clé = escrow_id).
  v_seller_res := public.credit_user_wallet_safe(v_seller, v_vendor_amount, v_cur, 'escrow_release', p_escrow_id::text);
  v_wallet_id  := (v_seller_res->>'wallet_id')::bigint;

  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, v_cur, 'escrow_commission', p_escrow_id::text);
  END IF;

  UPDATE public.escrow_transactions
  SET status = 'released', released_at = now(), commission_amount = v_commission, updated_at = now()
  WHERE id = p_escrow_id;

  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_wallet_id, receiver_user_id, amount, fee, net_amount, currency,
    transaction_type, status, description, metadata)
  VALUES (
    generate_transaction_id(), v_wallet_id, v_seller, v_escrow.amount, v_commission, v_vendor_amount, v_cur,
    'escrow_release', 'completed', 'Fonds escrow libérés',
    jsonb_build_object('escrow_id', p_escrow_id, 'order_id', v_escrow.order_id, 'commission', v_commission,
      'credited', (v_seller_res->>'credited')::numeric, 'credited_currency', v_seller_res->>'currency',
      'quarantined', (v_seller_res->>'quarantined')::numeric, 'idempotent', COALESCE((v_seller_res->>'idempotent')::boolean, false),
      'reason', p_reason, 'original_currency', v_cur));

  RETURN jsonb_build_object('success', true, 'escrow_id', p_escrow_id, 'vendor_amount', v_vendor_amount,
    'credited', (v_seller_res->>'credited')::numeric, 'credited_currency', v_seller_res->>'currency',
    'quarantined', (v_seller_res->>'quarantined')::numeric, 'commission_amount', v_commission);
END;
$$;
REVOKE ALL ON FUNCTION public.release_escrow_to_seller(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.release_escrow_to_seller(uuid, text) TO service_role;

-- 4) ── Surveillance : libérations créditées à 0 (argent bloqué en quarantaine) ──
CREATE OR REPLACE FUNCTION public.money_integrity_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_dup int; v_fx int; v_noc int; v_zc int;
BEGIN
  SELECT count(*) INTO v_dup FROM (
    SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname ~* '(credit_user_wallet_safe|create_order_core|release_escrow_to_seller|execute_atomic_wallet_transfer|refund_order_escrow|purchase_.*_subscription|create_pos_sale_complete)'
    GROUP BY p.proname HAVING count(*) > 1
  ) d;

  SELECT CASE WHEN EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'credit_user_wallet_safe'
      AND pg_get_functiondef(p.oid) LIKE '%FX_RATE_MISSING%'
  ) THEN 0 ELSE 1 END INTO v_fx;

  SELECT count(*) INTO v_noc
  FROM public.escrow_transactions e JOIN public.orders o ON o.id = e.order_id
  WHERE e.status = 'released' AND COALESCE(e.commission_amount, 0) = 0;

  -- Libérations escrow créditées à 0 (vendeur jamais payé : quarantaine/solde gonflé/anomalie).
  SELECT count(*) INTO v_zc
  FROM public.wallet_transactions
  WHERE transaction_type = 'escrow_release'
    AND COALESCE((metadata->>'credited')::numeric, 0) = 0;

  RETURN jsonb_build_object(
    'generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','money_duplicate_overload','label','Surcharges de fonctions argent en double (drift)','severity','critical','count',v_dup,'observed',v_dup),
      jsonb_build_object('key','credit_fx_not_converting','label','credit_user_wallet_safe sans conversion de devise','severity','critical','count',v_fx,'observed',v_fx),
      jsonb_build_object('key','escrow_released_no_commission','label','Escrows libérés sans commission prélevée','severity','critical','count',v_noc,'observed',v_noc),
      jsonb_build_object('key','escrow_released_zero_credit','label','Libérations escrow créditées à 0 (vendeur non payé / quarantaine)','severity','warning','count',v_zc,'observed',v_zc)
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public.money_integrity_report() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.money_integrity_report() TO authenticated, service_role;

SELECT 'Crédit wallet durci : idempotence par source (anti double-crédit) + escrow release avec clés de source + surveillance escrow_released_zero_credit.' AS status;
