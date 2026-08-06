-- ═══════════════════════════════════════════════════════════════════════════
-- COMPTABILITÉ — rapprochement RÉEL (v2) + agrégats PDG anonymisés. Migration NOUVELLE.
-- v1 comparait le journal-wallet aux wallet_transactions bruts (même source → toujours 0,
-- sans valeur). v2 compare le flux JOURNAL au DELTA RÉEL DU SOLDE (source INDÉPENDANTE :
-- wallet_balance_audit). Un solde qui bouge sans transaction (ou l'inverse) = écart = anomalie.
-- « La compta qui ne colle pas au wallet est une compta qui ment. »
-- ═══════════════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_wba_user_cur_date ON public.wallet_balance_audit (user_id, currency, changed_at DESC);

CREATE OR REPLACE FUNCTION public.accounting_reconcile(
  p_actor_id uuid, p_from timestamptz DEFAULT now() - interval '30 days', p_to timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; v_journal numeric; v_balance_delta numeric; v_gap numeric; v_dec int; v_out jsonb := '[]'::jsonb;
BEGIN
  IF p_actor_id <> auth.uid() AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;

  FOR r IN SELECT DISTINCT currency FROM public.wallets WHERE user_id = p_actor_id LOOP
    v_dec := public._ccy_decimals(r.currency);

    -- (1) Flux JOURNAL wallet sur la période (dérivé des transactions, via la vue compta).
    SELECT COALESCE(SUM(CASE WHEN j.direction='recette' THEN j.amount ELSE -j.amount END), 0)
      INTO v_journal FROM public.accounting_journal j
    WHERE j.actor_id = p_actor_id AND j.source_table = 'wallet_transactions'
      AND j.currency = r.currency AND j.entry_at >= p_from AND j.entry_at <= p_to;

    -- (2) DELTA RÉEL du solde sur la période — source INDÉPENDANTE (audit du solde).
    SELECT COALESCE(SUM(delta), 0) INTO v_balance_delta FROM public.wallet_balance_audit
    WHERE user_id = p_actor_id AND currency = r.currency
      AND changed_at >= p_from AND changed_at <= p_to;

    v_gap := round(v_journal - v_balance_delta, v_dec);
    v_out := v_out || jsonb_build_object('currency', r.currency, 'journal_flux', v_journal,
      'balance_delta', v_balance_delta, 'gap', v_gap, 'ok', abs(v_gap) <= power(10, -v_dec));

    -- Écart > tolérance → anomalie Fatome (réf datée par acteur+devise+jour, cf. dédup Sentinelle).
    IF abs(v_gap) > power(10, -v_dec) THEN
      PERFORM public.fatome_raise('accounting_gap',
        p_actor_id::text || ':' || r.currency || ':' || to_char(p_to, 'YYYY-MM-DD'), 'high',
        jsonb_build_object('actor', p_actor_id, 'currency', r.currency,
          'journal_flux', v_journal, 'balance_delta', v_balance_delta, 'gap', v_gap));
    END IF;
  END LOOP;
  RETURN jsonb_build_object('reconciliations', v_out);
END;
$$;
REVOKE ALL ON FUNCTION public.accounting_reconcile(uuid, timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accounting_reconcile(uuid, timestamptz, timestamptz) TO authenticated, service_role;

-- ── Agrégats PDG ANONYMISÉS (par catégorie + devise, totaux plateforme, PAS le détail individuel) ──
CREATE OR REPLACE FUNCTION public.get_accounting_pdg_aggregates(
  p_from timestamptz DEFAULT now() - interval '30 days', p_to timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_out jsonb;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  -- Totaux par catégorie + devise + direction + NOMBRE d'acteurs (anonymisé : jamais un acteur nommé).
  SELECT COALESCE(jsonb_agg(row_to_json(z)), '[]'::jsonb) INTO v_out FROM (
    SELECT j.category_code, j.currency, j.direction,
      SUM(j.amount) AS total, count(*) AS lignes, count(DISTINCT j.actor_id) AS acteurs
    FROM public.accounting_journal j
    WHERE j.entry_at >= p_from AND j.entry_at <= p_to
    GROUP BY j.category_code, j.currency, j.direction
    HAVING count(DISTINCT j.actor_id) >= 1
    ORDER BY total DESC
  ) z;
  RETURN jsonb_build_object('aggregates', v_out, 'generated_at', now());
END;
$$;
REVOKE ALL ON FUNCTION public.get_accounting_pdg_aggregates(timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_accounting_pdg_aggregates(timestamptz, timestamptz) TO authenticated, service_role;
