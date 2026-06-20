-- ============================================================================
-- AML — CONTRÔLES MANUELS PDG : geler un wallet + mettre un montant en quarantaine
-- ----------------------------------------------------------------------------
-- En plus de la quarantaine AUTOMATIQUE (dépassement de plafond), le PDG peut :
--   • quarantine_wallet_amount : prendre un montant du solde DÉPENSABLE actuel et le
--     mettre en quarantaine (atomique : débit du solde + ligne quarantaine 'pending').
--     Réversible par release_quarantined_funds (recrédit) ou reject.
--   • set_wallet_frozen : geler/dégeler tout le wallet (wallets.is_blocked). debitWallet
--     et les RPC de transfert honorent déjà is_blocked → bloque retraits + transferts.
-- aml_wallet_overview renvoie désormais is_blocked (état gelé) pour le panneau PDG.
-- Non destructif, rejouable.
-- ============================================================================

-- ───────────── Mettre un montant du solde actuel en quarantaine (manuel) ─────────────
CREATE OR REPLACE FUNCTION public.quarantine_wallet_amount(
  p_user_id uuid,
  p_amount  numeric,
  p_admin   uuid DEFAULT NULL,
  p_notes   text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id  bigint;
  v_bal numeric;
  v_cur text;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Montant invalide');
  END IF;

  SELECT id, balance, currency INTO v_id, v_bal, v_cur
  FROM public.wallets WHERE user_id = p_user_id ORDER BY id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet introuvable');
  END IF;
  IF COALESCE(v_bal, 0) < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solde dépensable insuffisant pour cette mise en quarantaine');
  END IF;

  -- Débit du solde dépensable → l'argent existe toujours mais passe en quarantaine.
  UPDATE public.wallets SET balance = balance - p_amount, updated_at = now() WHERE id = v_id;

  INSERT INTO public.wallet_quarantined_funds (
    user_id, wallet_id, amount, currency, source_type, reason, status, notes)
  VALUES (
    p_user_id, v_id, p_amount, v_cur, 'manual', 'manual_quarantine', 'pending',
    COALESCE(p_notes, 'Mise en quarantaine manuelle par PDG ' || COALESCE(p_admin::text, '')));

  RETURN jsonb_build_object('success', true, 'quarantined', p_amount, 'currency', v_cur, 'wallet_id', v_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- ───────────── Geler / dégeler un wallet entier ─────────────
CREATE OR REPLACE FUNCTION public.set_wallet_frozen(
  p_user_id uuid,
  p_frozen  boolean,
  p_admin   uuid DEFAULT NULL,
  p_reason  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.wallets
  SET is_blocked     = p_frozen,
      blocked_reason = CASE WHEN p_frozen THEN COALESCE(p_reason, 'Gelé par le PDG (contrôle AML)') ELSE NULL END,
      blocked_at     = CASE WHEN p_frozen THEN now() ELSE NULL END,
      updated_at     = now()
  WHERE user_id = p_user_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet introuvable');
  END IF;
  RETURN jsonb_build_object('success', true, 'frozen', p_frozen);
END;
$$;

REVOKE ALL ON FUNCTION public.quarantine_wallet_amount(uuid, numeric, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_wallet_frozen(uuid, boolean, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quarantine_wallet_amount(uuid, numeric, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.set_wallet_frozen(uuid, boolean, uuid, text) TO service_role;

-- ───────────── aml_wallet_overview : +is_blocked (état gelé) ─────────────
DROP FUNCTION IF EXISTS public.aml_wallet_overview(boolean, int);
CREATE OR REPLACE FUNCTION public.aml_wallet_overview(
  p_only_flagged boolean DEFAULT false,
  p_limit        int     DEFAULT 200
)
RETURNS TABLE(
  user_id             uuid,
  role                text,
  full_name           text,
  kyc_level           int,
  balance             numeric,
  currency            text,
  balance_gnf         numeric,
  effective_cap       numeric,
  over_cap            boolean,
  is_blocked          boolean,
  quarantined_pending numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    w.user_id,
    p.role,
    NULLIF(TRIM(COALESCE(p.first_name,'') || ' ' || COALESCE(p.last_name,'')), '') AS full_name,
    COALESCE(p.kyc_level, 0) AS kyc_level,
    w.balance,
    w.currency,
    public.convert_to_gnf(COALESCE(w.balance, 0), w.currency) AS balance_gnf,
    public.wallet_effective_cap(w.user_id) AS effective_cap,
    (public.wallet_effective_cap(w.user_id) IS NOT NULL
      AND public.convert_to_gnf(COALESCE(w.balance, 0), w.currency) > public.wallet_effective_cap(w.user_id) + 1) AS over_cap,
    COALESCE(w.is_blocked, false) AS is_blocked,
    COALESCE((SELECT sum(q.amount) FROM public.wallet_quarantined_funds q
              WHERE q.user_id = w.user_id AND q.status = 'pending'), 0) AS quarantined_pending
  FROM public.wallets w
  LEFT JOIN public.profiles p ON p.id = w.user_id
  WHERE (NOT p_only_flagged)
     OR (public.wallet_effective_cap(w.user_id) IS NOT NULL
         AND public.convert_to_gnf(COALESCE(w.balance, 0), w.currency) > public.wallet_effective_cap(w.user_id) + 1)
     OR COALESCE(w.is_blocked, false) = true
  ORDER BY public.convert_to_gnf(COALESCE(w.balance, 0), w.currency) DESC
  LIMIT p_limit;
$$;

REVOKE ALL ON FUNCTION public.aml_wallet_overview(boolean, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.aml_wallet_overview(boolean, int) TO service_role;

SELECT 'Contrôles manuels AML : quarantine_wallet_amount + set_wallet_frozen + aml_wallet_overview(+is_blocked).' AS status;
