-- ═══════════════════════════════════════════════════════════════════════════
-- FIX AFFILIATION — devise SOURCE des abonnements (base de calcul).
-- La commission d'affiliation raisonne en GNF (base du coffre PDG). Le montant SOURCE (grille par
-- pays : XOF/SLE/EUR…) est désormais converti source→GNF TRACÉ dans le service avant le crédit
-- (triggerAffiliateCommission). Cette migration : (1) trace le leg SOURCE→GNF sur agent_commissions_log
-- (colonnes base_*), (2) fournit un rattrapage versionné idempotent des commissions d'abonnement
-- sous-payées (base = prix brut au lieu de prix × taux). Migration NOUVELLE, additive.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- 1) Traçage du leg SOURCE→GNF (leg agent = colonnes credited_* déjà en place). Historique NULL.
ALTER TABLE public.agent_commissions_log
  ADD COLUMN IF NOT EXISTS base_currency   text,        -- devise SOURCE (XOF/SLE/EUR… ou GNF)
  ADD COLUMN IF NOT EXISTS base_amount      numeric,    -- montant SOURCE (avant conversion)
  ADD COLUMN IF NOT EXISTS base_fx_rate     numeric,    -- taux source→GNF
  ADD COLUMN IF NOT EXISTS base_fx_rate_at  timestamptz,
  ADD COLUMN IF NOT EXISTS base_fx_source   text;

-- Nouvelle raison de mise en attente : taux SOURCE (devise grille→GNF) indisponible.
ALTER TABLE public.affiliate_commission_pending DROP CONSTRAINT IF EXISTS affiliate_commission_pending_reason_check;
ALTER TABLE public.affiliate_commission_pending
  ADD CONSTRAINT affiliate_commission_pending_reason_check CHECK (reason IN ('NO_RATE','FX_DOWN','NO_RATE_SOURCE'));

-- 2) Devise source d'une souscription (cherchée dans les 3 tables porteuses de metadata.pricing_currency).
CREATE OR REPLACE FUNCTION public._subscription_pricing_currency(p_sub_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $sc$
  SELECT upper(COALESCE(
    (SELECT s.metadata->>'pricing_currency'  FROM public.subscriptions s        WHERE s.id = p_sub_id),
    (SELECT ss.metadata->>'pricing_currency' FROM public.service_subscriptions ss WHERE ss.id = p_sub_id),
    (SELECT ds.metadata->>'pricing_currency' FROM public.driver_subscriptions ds  WHERE ds.id = p_sub_id),
    'GNF'));
$sc$;
REVOKE ALL ON FUNCTION public._subscription_pricing_currency(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._subscription_pricing_currency(uuid) TO authenticated, service_role;

-- 3) RATTRAPAGE versionné (idempotent) des commissions d'abonnement sous-payées.
--    Cible : source_type='abonnement', leg source NON tracé (base_currency NULL) ET souscription liée
--    en devise ≠ GNF (donc base utilisée = prix BRUT au lieu de prix × taux). Pour chacune : on crédite
--    le DELTA de base (correct_base_gnf − base_brute) via le moteur normal, avec une clé d'idempotence
--    DÉTERMINISTE (md5('rattrapage_sub_ccy:'||sub_id)) → un re-run ne double JAMAIS. Wallet agent absent
--    → pending (géré par credit_agent_commission/triggerAffiliateCommission côté service).
--    Taux : taux FRAIS courant (_acash_fx) — documenté ; une variante fx_rate_history à la date de la
--    souscription se substituerait ici si des lignes existaient (0 aujourd'hui → aucune différence).
CREATE OR REPLACE FUNCTION public.affiliate_backfill_subscription_ccy()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $bf$
DECLARE r record; v_src text; v_fx jsonb; v_rate numeric; v_correct numeric; v_delta numeric;
  v_key uuid; v_res jsonb; v_n int := 0; v_total numeric := 0; v_skipped int := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT l.transaction_id AS sub_id, l.related_user_id AS user_id, l.transaction_amount AS base_brute
    FROM public.agent_commissions_log l
    WHERE l.source_type = 'abonnement' AND l.base_currency IS NULL
      AND public._subscription_pricing_currency(l.transaction_id) <> 'GNF'
  LOOP
    v_src := public._subscription_pricing_currency(r.sub_id);
    BEGIN
      v_fx := public._acash_fx(r.base_brute, v_src, 'GNF');   -- prix source (=base brute) → GNF
      v_correct := (v_fx->>'converted')::numeric;
    EXCEPTION WHEN OTHERS THEN v_correct := NULL; END;
    IF v_correct IS NULL OR v_correct <= r.base_brute THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    v_delta := ROUND(v_correct - r.base_brute, 2);          -- delta de BASE à commissionner
    v_key := md5('rattrapage_sub_ccy:' || r.sub_id::text)::uuid;   -- idempotent (transaction_id, user)
    v_res := public.credit_agent_commission(r.user_id, v_delta, 'abonnement_rattrapage_ccy', v_key,
               jsonb_build_object('currency','GNF','rattrapage_de', r.sub_id, 'devise_source', v_src));
    IF COALESCE((v_res->>'success')::boolean, false) AND COALESCE((v_res->>'has_agent')::boolean, false)
       AND NOT COALESCE((v_res->>'already_processed')::boolean, false) THEN
      v_n := v_n + 1; v_total := v_total + COALESCE((v_res->>'total_commissions')::numeric, 0);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('rattrapees', v_n, 'ignorees', v_skipped, 'total_commission_gnf', v_total, 'ran_at', now());
END; $bf$;
REVOKE ALL ON FUNCTION public.affiliate_backfill_subscription_ccy() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.affiliate_backfill_subscription_ccy() TO service_role;

COMMIT;
