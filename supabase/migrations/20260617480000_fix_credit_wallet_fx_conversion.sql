-- ============================================================================
-- 🔧 CONVERSION DEVISE AU CRÉDIT WALLET — correctif (fuite « 60000 GNF → 60000 EUR »).
--
-- Constat (données live) : un vendeur en EUR recevait 60000 (montant escrow GNF) crédité
-- TEL QUEL = 60000 EUR au lieu de ~5,93 EUR (60000 × 0.00009889). Les taux GNF↔EUR existent
-- pourtant. Cause = DRIFT : la base tourne une ANCIENNE surcharge `credit_user_wallet_safe(
-- uuid,numeric,text)` SANS conversion ; comme release_escrow_to_seller appelle la fonction en
-- 3 arguments, c'est cette ancienne surcharge non-convertissante qui répond.
--
-- Fix : on SUPPRIME l'ancienne surcharge 3-args et on (ré)installe la version qui :
--   1) convertit vers la devise du wallet via currency_exchange_rates (paire directe/inverse),
--   2) si pas de paire directe → CROSS via USD (comme le résolveur des transferts),
--   3) ❗ si aucun taux fiable trouvé en cross-devise → LÈVE une exception (FX_RATE_MISSING)
--      au lieu de créditer au taux 1.0 (fini les sur-crédits ~10 000×),
--   4) applique le plafond/quarantaine AML (apply_wallet_cap_split) sur le montant CONVERTI.
--
-- credit_user_wallet_safe est utilisée partout (escrow, commissions, remboursements, dépôts) :
-- ce correctif bénéficie à TOUS les crédits cross-devise. Idempotent.
-- ⚠️ Après application : REDÉPLOYER le backend (cohérence) puis refaire un achat test.
-- ============================================================================

-- Retirer l'ancienne surcharge 3-args (non-convertissante) qui captait les appels en 3 arguments.
DROP FUNCTION IF EXISTS public.credit_user_wallet_safe(uuid, numeric, text);

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

  -- ── Conversion vers la devise du wallet ────────────────────────────────────
  IF p_from_currency IS NULL OR v_wallet_cur = p_from_currency THEN
    v_credit := p_amount;
  ELSE
    -- 1) Paire directe ou inverse.
    SELECT CASE WHEN cer.from_currency = p_from_currency THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END
    INTO v_rate
    FROM public.currency_exchange_rates cer
    WHERE ((cer.from_currency = p_from_currency AND cer.to_currency = v_wallet_cur)
        OR (cer.from_currency = v_wallet_cur AND cer.to_currency = p_from_currency))
      AND cer.is_active = true
    ORDER BY cer.retrieved_at DESC LIMIT 1;

    -- 2) Cross via USD (from→USD × USD→wallet) si pas de paire directe.
    IF v_rate IS NULL OR v_rate <= 0 THEN
      SELECT CASE WHEN cer.from_currency = p_from_currency THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END
      INTO v_from_usd
      FROM public.currency_exchange_rates cer
      WHERE ((cer.from_currency = p_from_currency AND cer.to_currency = 'USD')
          OR (cer.from_currency = 'USD' AND cer.to_currency = p_from_currency))
        AND cer.is_active = true
      ORDER BY cer.retrieved_at DESC LIMIT 1;

      SELECT CASE WHEN cer.from_currency = 'USD' THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END
      INTO v_usd_to
      FROM public.currency_exchange_rates cer
      WHERE ((cer.from_currency = 'USD' AND cer.to_currency = v_wallet_cur)
          OR (cer.from_currency = v_wallet_cur AND cer.to_currency = 'USD'))
        AND cer.is_active = true
      ORDER BY cer.retrieved_at DESC LIMIT 1;

      IF v_from_usd IS NOT NULL AND v_from_usd > 0 AND v_usd_to IS NOT NULL AND v_usd_to > 0 THEN
        v_rate := v_from_usd * v_usd_to;
      END IF;
    END IF;

    -- 3) SÉCURITÉ : aucun taux fiable → NE PAS créditer au taux 1.0 (fuite). On lève.
    IF v_rate IS NULL OR v_rate <= 0 THEN
      RAISE EXCEPTION 'FX_RATE_MISSING: taux introuvable % → % (crédit refusé pour éviter un montant non converti)', p_from_currency, v_wallet_cur;
    END IF;

    v_credit := ROUND(p_amount * v_rate, 2);
  END IF;

  -- ── Plafond + quarantaine AML via le helper unique (sur le montant CONVERTI) ──
  -- Résilient au drift : si le helper AML n'existe pas encore en base, on crédite le
  -- montant CONVERTI complet (la conversion, elle, ne doit jamais être contournée).
  BEGIN
    v_credited := public.apply_wallet_cap_split(p_user_id, v_wallet_id, COALESCE(v_bal, 0), v_credit, v_wallet_cur, p_source_type, p_source_txn_id);
  EXCEPTION WHEN undefined_function THEN
    v_credited := v_credit;
  END;
  v_q_amt    := v_credit - v_credited;

  IF v_credited > 0 THEN
    UPDATE public.wallets SET balance = COALESCE(balance, 0) + v_credited, updated_at = now() WHERE id = v_wallet_id;
  END IF;

  RETURN jsonb_build_object('credited', v_credited, 'currency', v_wallet_cur, 'wallet_id', v_wallet_id,
    'quarantined', v_q_amt, 'capped', (v_q_amt > 0));
END;
$$;

REVOKE ALL ON FUNCTION public.credit_user_wallet_safe(uuid, numeric, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_user_wallet_safe(uuid, numeric, text, text, text) TO authenticated, service_role;

SELECT 'credit_user_wallet_safe : conversion devise (directe/inverse + cross USD) + exception si taux manquant (fini le crédit non converti). Ancienne surcharge 3-args supprimée.' AS status;
