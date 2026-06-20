-- ============================================================================
-- CONTRÔLE DE PROVENANCE & PLAFOND DE WALLET (AML) — ENFORCEMENT (2/3)
-- ----------------------------------------------------------------------------
-- credit_user_wallet_safe est LE primitif atomique de crédit (escrow release,
-- remboursement, commission, etc.). On y ajoute le PLAFOND : si un crédit ferait
-- dépasser le plafond de détention de l'utilisateur, l'EXCÉDENT part en
-- QUARANTAINE (wallet_quarantined_funds) au lieu d'augmenter le solde dépensable.
-- Aucun argent n'est détruit ; il est conservé, non dépensable, en attente de
-- justification / montée KYC / validation PDG.
--
-- Compat : 2 nouveaux paramètres OPTIONNELS (source_type, source_txn_id) → les
-- appelants existants (3 args) continuent de fonctionner via les valeurs par défaut.
-- Le calcul plafond se fait en GNF (référence) puis l'excédent est mis en
-- quarantaine PROPORTIONNELLEMENT dans la devise du wallet (cohérent multi-devise).
-- PDG/système exemptés (wallet_effective_cap renvoie NULL). Non destructif, rejouable.
-- ============================================================================

-- L'ajout de paramètres change la signature → on retire l'ancienne (3 args) d'abord.
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
  v_cap_gnf    numeric;
  v_bal_gnf    numeric;
  v_credit_gnf numeric;
  v_over_gnf   numeric;
  v_q_frac     numeric;
  v_q_amt      numeric := 0;
  v_credited   numeric;
BEGIN
  IF p_user_id IS NULL OR COALESCE(p_amount, 0) <= 0 THEN
    RETURN jsonb_build_object('credited', 0, 'currency', p_from_currency, 'skipped', true);
  END IF;

  -- L'utilisateur a AU PLUS un wallet (contrainte unique). On le verrouille.
  SELECT id, currency, balance INTO v_wallet_id, v_wallet_cur, v_bal
  FROM public.wallets
  WHERE user_id = p_user_id
  ORDER BY (currency = p_from_currency) DESC, id ASC
  LIMIT 1
  FOR UPDATE;

  -- Aucun wallet → on en crée un à 0 (la logique de plafond s'applique ensuite uniformément).
  IF v_wallet_id IS NULL THEN
    INSERT INTO public.wallets (user_id, balance, currency, wallet_status)
    VALUES (p_user_id, 0, COALESCE(p_from_currency, 'GNF'), 'active')
    RETURNING id, currency, balance INTO v_wallet_id, v_wallet_cur, v_bal;
  END IF;

  -- Conversion du crédit vers la devise du wallet si nécessaire.
  IF p_from_currency IS NULL OR v_wallet_cur = p_from_currency THEN
    v_credit := p_amount;
  ELSE
    SELECT CASE WHEN cer.from_currency = p_from_currency
                THEN cer.rate ELSE 1.0 / NULLIF(cer.rate, 0) END
    INTO v_rate
    FROM public.currency_exchange_rates cer
    WHERE ((cer.from_currency = p_from_currency AND cer.to_currency = v_wallet_cur)
        OR (cer.from_currency = v_wallet_cur AND cer.to_currency = p_from_currency))
      AND cer.is_active = true
    ORDER BY cer.retrieved_at DESC
    LIMIT 1;
    v_credit := ROUND(p_amount * COALESCE(v_rate, 1.0), 2);
  END IF;

  -- ===== PLAFOND DE DÉTENTION (quarantaine de l'excédent) =====
  v_cap_gnf  := public.wallet_effective_cap(p_user_id);   -- NULL = illimité / exempté
  v_credited := v_credit;

  IF v_cap_gnf IS NOT NULL THEN
    v_bal_gnf    := public.convert_to_gnf(COALESCE(v_bal, 0), v_wallet_cur);
    v_credit_gnf := public.convert_to_gnf(v_credit, v_wallet_cur);
    v_over_gnf   := (v_bal_gnf + v_credit_gnf) - v_cap_gnf;

    IF v_over_gnf > 0 AND v_credit_gnf > 0 THEN
      -- Fraction du crédit qui dépasse le plafond → quarantaine (proportionnelle, devise du wallet).
      v_q_frac   := LEAST(v_over_gnf / v_credit_gnf, 1.0);
      v_q_amt    := ROUND(v_credit * v_q_frac, 2);
      v_credited := v_credit - v_q_amt;
    END IF;
  END IF;

  -- Crédit de la part autorisée (sous le plafond).
  IF v_credited > 0 THEN
    UPDATE public.wallets SET balance = COALESCE(balance, 0) + v_credited, updated_at = now()
    WHERE id = v_wallet_id;
  END IF;

  -- Mise en quarantaine de l'excédent (conservé, non dépensable).
  IF v_q_amt > 0 THEN
    INSERT INTO public.wallet_quarantined_funds (
      user_id, wallet_id, amount, currency, source_transaction_id, source_type, reason, status)
    VALUES (
      p_user_id, v_wallet_id, v_q_amt, v_wallet_cur, p_source_txn_id, p_source_type, 'cap_exceeded', 'pending');
  END IF;

  RETURN jsonb_build_object(
    'credited', v_credited, 'currency', v_wallet_cur, 'wallet_id', v_wallet_id,
    'quarantined', v_q_amt, 'capped', (v_q_amt > 0));
END;
$$;

REVOKE ALL ON FUNCTION public.credit_user_wallet_safe(uuid, numeric, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_user_wallet_safe(uuid, numeric, text, text, text) TO authenticated, service_role;

SELECT 'credit_user_wallet_safe : plafond + quarantaine actifs (excédent conservé, non dépensable).' AS status;
