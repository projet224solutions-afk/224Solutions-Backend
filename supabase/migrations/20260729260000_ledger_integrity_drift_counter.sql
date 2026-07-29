-- ============================================================================
-- COMPTEUR DE DÉRIVE (surveillance C.2) — la preuve comptable continue, au centime
-- ----------------------------------------------------------------------------
-- Job qui vérifie des INVARIANTS EXACTS (pas d'approximatif) et alerte en CRITIQUE au moindre
-- écart. Résultats historisés → le PDG voit que « tout était juste » à chaque passage.
-- N'inclut que des invariants calculables au centime et SANS faux positif ; les invariants
-- cross-ledger plus fins (Σ dépôts = Σ crédités+frais+quarantaine) seront ajoutés au fur et à
-- mesure, une fois la vue unifiée v_money_movements en place.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.ledger_integrity_checks (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  checked_at   timestamptz NOT NULL DEFAULT now(),
  check_name   text NOT NULL,
  scope        text,                 -- devise ou sous-portée éventuelle
  expected     numeric,
  actual       numeric,
  drift        numeric,              -- actual - expected ; 0 = parfait
  ok           boolean NOT NULL,
  details      jsonb DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_lic_checked ON public.ledger_integrity_checks(checked_at DESC);
CREATE INDEX IF NOT EXISTS idx_lic_bad ON public.ledger_integrity_checks(checked_at DESC) WHERE ok = false;
ALTER TABLE public.ledger_integrity_checks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lic_admin_read ON public.ledger_integrity_checks;
CREATE POLICY lic_admin_read ON public.ledger_integrity_checks FOR SELECT TO authenticated USING (public.is_admin_or_pdg());

CREATE OR REPLACE FUNCTION public.run_ledger_integrity_check()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_bad int := 0; v_total int := 0;
  v_n numeric;
BEGIN
  -- Chaque invariant : actual == expected au centime, sinon ligne rouge (ok=false).

  -- 1) Aucun wallet à solde négatif (création/perte d'argent).
  SELECT count(*) INTO v_n FROM public.wallets WHERE COALESCE(balance,0) < 0;
  INSERT INTO public.ledger_integrity_checks(check_name, expected, actual, drift, ok, details)
  VALUES ('no_negative_wallet', 0, v_n, v_n - 0, v_n = 0,
    jsonb_build_object('run', v_run));
  v_total := v_total + 1; IF v_n <> 0 THEN v_bad := v_bad + 1; END IF;

  -- 2) Aucun lot FIFO à reste négatif.
  SELECT count(*) INTO v_n FROM public.agent_cash_deposit_lots WHERE amount_remaining < 0;
  INSERT INTO public.ledger_integrity_checks(check_name, expected, actual, drift, ok, details)
  VALUES ('fifo_no_negative_remaining', 0, v_n, v_n, v_n = 0, jsonb_build_object('run', v_run));
  v_total := v_total + 1; IF v_n <> 0 THEN v_bad := v_bad + 1; END IF;

  -- 3) Aucun lot FIFO sur-consommé (reste > initial).
  SELECT count(*) INTO v_n FROM public.agent_cash_deposit_lots WHERE amount_remaining > amount_initial;
  INSERT INTO public.ledger_integrity_checks(check_name, expected, actual, drift, ok, details)
  VALUES ('fifo_not_overconsumed', 0, v_n, v_n, v_n = 0, jsonb_build_object('run', v_run));
  v_total := v_total + 1; IF v_n <> 0 THEN v_bad := v_bad + 1; END IF;

  -- 4) Quarantaine : aucun statut invalide (conservation pending|released|rejected).
  SELECT count(*) INTO v_n FROM public.wallet_quarantined_funds
   WHERE status NOT IN ('pending','released','rejected');
  INSERT INTO public.ledger_integrity_checks(check_name, expected, actual, drift, ok, details)
  VALUES ('quarantine_status_valid', 0, v_n, v_n, v_n = 0, jsonb_build_object('run', v_run));
  v_total := v_total + 1; IF v_n <> 0 THEN v_bad := v_bad + 1; END IF;

  -- 5) Retraits : aucun état incohérent (payé ET remboursé, ou montant négatif, ou statut hors machine).
  SELECT count(*) INTO v_n FROM public.withdrawals
   WHERE (status = 'paid' AND refunded_at IS NOT NULL)
      OR (status = 'refunded' AND paid_at IS NOT NULL)
      OR amount < 0
      OR status NOT IN ('pending','processing','paid','refunded','failed');
  INSERT INTO public.ledger_integrity_checks(check_name, expected, actual, drift, ok, details)
  VALUES ('withdrawals_state_coherent', 0, v_n, v_n, v_n = 0, jsonb_build_object('run', v_run));
  v_total := v_total + 1; IF v_n <> 0 THEN v_bad := v_bad + 1; END IF;

  -- 6) Dépôts : aucune ligne 'completed' sans credited_at (crédit non tracé).
  SELECT count(*) INTO v_n FROM public.payment_transactions
   WHERE status = 'completed' AND credited_at IS NULL;
  INSERT INTO public.ledger_integrity_checks(check_name, expected, actual, drift, ok, details)
  VALUES ('payment_completed_has_credit', 0, v_n, v_n, v_n = 0, jsonb_build_object('run', v_run));
  v_total := v_total + 1; IF v_n <> 0 THEN v_bad := v_bad + 1; END IF;

  -- 7) Une même preuve de paiement ne crédite qu'une fois (provider_ref unique) — garanti par
  --    contrainte ; on vérifie qu'aucun doublon crédité n'existe (défense).
  SELECT count(*) INTO v_n FROM (
    SELECT provider, provider_ref FROM public.payment_transactions
     WHERE credited_at IS NOT NULL GROUP BY provider, provider_ref HAVING count(*) > 1) d;
  INSERT INTO public.ledger_integrity_checks(check_name, expected, actual, drift, ok, details)
  VALUES ('payment_no_double_credit', 0, v_n, v_n, v_n = 0, jsonb_build_object('run', v_run));
  v_total := v_total + 1; IF v_n <> 0 THEN v_bad := v_bad + 1; END IF;

  -- Alerte CRITIQUE au moindre écart (une par run, avec le détail des invariants rouges).
  IF v_bad > 0 THEN
    INSERT INTO public.system_alerts(severity, module, title, message, metadata)
    VALUES ('critical', 'ledger_integrity',
      'DÉRIVE COMPTABLE détectée (' || v_bad || '/' || v_total || ' invariants rouges)',
      'Au moins un invariant comptable a un écart. Voir ledger_integrity_checks (run ' || v_run || ').',
      jsonb_build_object('run', v_run, 'bad', v_bad, 'total', v_total));
  END IF;

  RETURN jsonb_build_object('run', v_run, 'checked_at', now(), 'total', v_total, 'bad', v_bad,
    'all_ok', v_bad = 0);
END $function$;

REVOKE ALL ON FUNCTION public.run_ledger_integrity_check() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.run_ledger_integrity_check() TO service_role;
