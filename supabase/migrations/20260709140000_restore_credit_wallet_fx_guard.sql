-- ============================================================================
-- 🔴 RESTAURATION garde FX + idempotence — credit_user_wallet_safe
-- ----------------------------------------------------------------------------
-- INCIDENT (alerte credit_fx_not_converting, 9 juil 2026) : la fonction LIVE en base
-- avait régressé vers un CORPS DU 8 JUIN (quarantaine inline, SANS garde FX_RATE_MISSING
-- NI idempotence). Cause : ré-application HORS-ORDRE d'une migration AML du 8 juin
-- (20260608280001 / 20260608290000) — le repo, lui, était sain.
--
-- ⚠️ On NE restaure PAS la version du 17 juin (20260617480000) : elle est PÉRIMÉE (perdrait
-- l'idempotence par source). On restaure STRICTEMENT le corps CANONIQUE du 18 juin
-- (20260618160000_harden_wallet_credit_atomic) = garde FX + idempotence anti-double-crédit + AML.
--
-- Défensif, rejouable, auto-vérifié. Ne touche QUE credit_user_wallet_safe.
-- ============================================================================

-- 0) ── Dépendance : registre d'idempotence (présent si le 18 juin avait été appliqué) ──
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

-- 1) ── DROP défensif d'une éventuelle signature obsolète (3 args) ──
--    (la signature canonique = 5 args ; CREATE OR REPLACE ci-dessous la remplace.)
DROP FUNCTION IF EXISTS public.credit_user_wallet_safe(uuid, numeric, text);

-- 2) ── Corps CANONIQUE (copie stricte de 20260618160000) ──
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

-- 3) ── Sentinelle anti-régression (documentaire) ──
COMMENT ON FUNCTION public.credit_user_wallet_safe(uuid, numeric, text, text, text) IS
  'CANONIQUE v20260618160000+ — garde FX_RATE_MISSING + idempotence par source OBLIGATOIRES. NE JAMAIS recréer sans ces gardes. Surveillé par money_integrity_report (alerte critical credit_fx_not_converting).';

-- 4) ── Auto-vérification (échoue bruyamment si la restauration est incomplète) ──
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname='public' AND p.proname='credit_user_wallet_safe'
      AND pg_get_functiondef(p.oid) LIKE '%FX_RATE_MISSING%'
  ) THEN
    RAISE EXCEPTION 'GARDE FX ABSENT après restauration — migration invalide';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname='public' AND p.proname='credit_user_wallet_safe'
      AND pg_get_functiondef(p.oid) LIKE '%wallet_credit_idempotency%'
  ) THEN
    RAISE EXCEPTION 'IDEMPOTENCE ABSENTE après restauration — version périmée';
  END IF;
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname='credit_user_wallet_safe') <> 1 THEN
    RAISE EXCEPTION 'Surcharges multiples de credit_user_wallet_safe — nettoyer avant de continuer';
  END IF;
  RAISE NOTICE 'OK : garde FX + idempotence présents, 1 seule surcharge.';
END $$;

-- 5) ── Garde anti-régression PERMANENT : journalisation DDL des fonctions argent ──
--    Table dédiée (audit_logs.actor_id est NOT NULL + FK → inadapté à un event trigger).
CREATE TABLE IF NOT EXISTS public.money_function_ddl_audit (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  proname         text,
  object_identity text,
  command_tag     text,
  ddl_role        text DEFAULT current_user,
  at              timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.money_function_ddl_audit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mfda_admin_read ON public.money_function_ddl_audit;
CREATE POLICY mfda_admin_read ON public.money_function_ddl_audit FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());

CREATE OR REPLACE FUNCTION public.audit_money_function_ddl()
RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
    IF r.object_identity ~* '(credit_user_wallet_safe|create_order_core|release_escrow_to_seller|execute_atomic_wallet_transfer|refund_order_escrow|purchase_.*_subscription|create_pos_sale_complete)' THEN
      INSERT INTO public.money_function_ddl_audit (proname, object_identity, command_tag)
      VALUES (split_part(split_part(r.object_identity, '.', 2), '(', 1), r.object_identity, r.command_tag);
    END IF;
  END LOOP;
END $$;

-- Event trigger EXCEPTION-SAFE : un refus de privilège ne doit JAMAIS rollback la restauration.
DO $$
BEGIN
  BEGIN
    EXECUTE 'DROP EVENT TRIGGER IF EXISTS trg_audit_money_function_ddl';
    EXECUTE 'CREATE EVENT TRIGGER trg_audit_money_function_ddl ON ddl_command_end '
         || 'WHEN TAG IN (''CREATE FUNCTION'', ''ALTER FUNCTION'') '
         || 'EXECUTE FUNCTION public.audit_money_function_ddl()';
    RAISE NOTICE 'Event trigger anti-régression installé.';
  EXCEPTION WHEN insufficient_privilege OR feature_not_supported THEN
    RAISE NOTICE 'Event trigger non autorisé sur ce plan — le monitor money_integrity_report 24/7 reste le filet.';
  END;
END $$;

SELECT 'credit_user_wallet_safe restauré (canonique 18 juin : garde FX + idempotence) + sentinelle + audit DDL.' AS status;
