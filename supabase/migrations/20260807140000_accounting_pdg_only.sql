-- ═══ COMPTABILITÉ PDG-ONLY : verrouiller les RPC de lecture (migration nouvelle). ═══
-- L'acteur n'accède PLUS au journal/synthèse/rapprochement (is_admin_or_pdg obligatoire).
-- Les RPC de SAISIE (accounting_add_expense/cash_course) restent accessibles à l'acteur
-- pour LUI-MÊME (écriture seule) : capture de donnée ≠ gestion comptable.

CREATE OR REPLACE FUNCTION public.get_accounting_summary(p_actor_id uuid, p_from timestamp with time zone DEFAULT (now() - '30 days'::interval), p_to timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_by_currency jsonb; v_by_category jsonb; v_daily jsonb;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;

  -- Par devise : recettes / dépenses / résultat (le résultat EXCLUT la trésorerie affects_result=false).
  SELECT COALESCE(jsonb_object_agg(cur, obj), '{}'::jsonb) INTO v_by_currency FROM (
    SELECT j.currency AS cur, jsonb_build_object(
      'recettes', SUM(CASE WHEN j.direction='recette' THEN j.amount ELSE 0 END),
      'depenses', SUM(CASE WHEN j.direction='depense' THEN j.amount ELSE 0 END),
      'resultat', SUM(CASE WHEN c.affects_result AND j.direction='recette' THEN j.amount
                           WHEN c.affects_result AND j.direction='depense' THEN -j.amount ELSE 0 END)
    ) AS obj
    FROM public.accounting_journal j JOIN public.accounting_categories c ON c.code = j.category_code
    WHERE j.actor_id = p_actor_id AND j.entry_at >= p_from AND j.entry_at <= p_to
    GROUP BY j.currency
  ) z;

  -- Par catégorie + devise (pour le détail des cartes).
  SELECT COALESCE(jsonb_agg(row_to_json(y)), '[]'::jsonb) INTO v_by_category FROM (
    SELECT j.category_code, j.currency, j.direction, SUM(j.amount) AS total, count(*) AS n
    FROM public.accounting_journal j
    WHERE j.actor_id = p_actor_id AND j.entry_at >= p_from AND j.entry_at <= p_to
    GROUP BY j.category_code, j.currency, j.direction ORDER BY total DESC
  ) y;

  -- Série quotidienne (résultat net par jour et devise) pour le graphique.
  SELECT COALESCE(jsonb_agg(row_to_json(d)), '[]'::jsonb) INTO v_daily FROM (
    SELECT j.entry_at::date AS day, j.currency,
      SUM(CASE WHEN c.affects_result AND j.direction='recette' THEN j.amount
              WHEN c.affects_result AND j.direction='depense' THEN -j.amount ELSE 0 END) AS net
    FROM public.accounting_journal j JOIN public.accounting_categories c ON c.code = j.category_code
    WHERE j.actor_id = p_actor_id AND j.entry_at >= p_from AND j.entry_at <= p_to
    GROUP BY 1,2 ORDER BY 1
  ) d;

  RETURN jsonb_build_object('by_currency', v_by_currency, 'by_category', v_by_category, 'daily', v_daily);
END;
$function$
;
CREATE OR REPLACE FUNCTION public.get_accounting_journal(p_actor_id uuid, p_from timestamp with time zone DEFAULT (now() - '30 days'::interval), p_to timestamp with time zone DEFAULT now(), p_category text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_rows jsonb; v_total int;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT count(*) INTO v_total FROM public.accounting_journal j
  WHERE j.actor_id = p_actor_id AND j.entry_at >= p_from AND j.entry_at <= p_to
    AND (p_category IS NULL OR j.category_code = p_category)
    AND (p_source IS NULL OR j.source_table = p_source);
  SELECT COALESCE(jsonb_agg(row_to_json(r)), '[]'::jsonb) INTO v_rows FROM (
    SELECT j.entry_at, j.direction, j.category_code, j.label, j.amount, j.currency, j.source_table, j.source_id
    FROM public.accounting_journal j
    WHERE j.actor_id = p_actor_id AND j.entry_at >= p_from AND j.entry_at <= p_to
      AND (p_category IS NULL OR j.category_code = p_category)
      AND (p_source IS NULL OR j.source_table = p_source)
    ORDER BY j.entry_at DESC LIMIT greatest(1, least(p_limit, 200)) OFFSET greatest(0, p_offset)
  ) r;
  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END;
$function$
;
CREATE OR REPLACE FUNCTION public.accounting_reconcile(p_actor_id uuid, p_from timestamp with time zone DEFAULT (now() - '30 days'::interval), p_to timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r record; v_journal numeric; v_balance_delta numeric; v_gap numeric; v_dec int; v_out jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;

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
$function$
;