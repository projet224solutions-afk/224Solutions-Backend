-- ═══════════════════════════════════════════════════════════════════════════
-- COMPTABILITÉ — RPC de synthèse / journal / rapprochement. Ownership STRICT :
-- l'acteur ne voit QUE lui (auth.uid()) ; PDG/admin peut lire (agrégats). JAMAIS de somme
-- inter-devises. Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════

-- Index de perf sur les colonnes de filtrage des sources (le journal est une vue → on indexe
-- les tables sous-jacentes). wallet_transactions par acteur+date (les 2 perspectives).
CREATE INDEX IF NOT EXISTS idx_wt_receiver_date ON public.wallet_transactions (receiver_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wt_sender_date ON public.wallet_transactions (sender_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pcs_provider_date ON public.provider_cash_sales (provider_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tt_driver_completed ON public.taxi_trips (driver_id, completed_at DESC);

-- Synthèse : par DEVISE → recettes, dépenses, résultat (hors trésorerie) + série quotidienne.
CREATE OR REPLACE FUNCTION public.get_accounting_summary(
  p_actor_id uuid, p_from timestamptz DEFAULT now() - interval '30 days', p_to timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_by_currency jsonb; v_by_category jsonb; v_daily jsonb;
BEGIN
  IF p_actor_id <> auth.uid() AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;

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
$$;
REVOKE ALL ON FUNCTION public.get_accounting_summary(uuid, timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_accounting_summary(uuid, timestamptz, timestamptz) TO authenticated, service_role;

-- Journal détaillé paginé (filtres catégorie/source + recherche).
CREATE OR REPLACE FUNCTION public.get_accounting_journal(
  p_actor_id uuid, p_from timestamptz DEFAULT now() - interval '30 days', p_to timestamptz DEFAULT now(),
  p_category text DEFAULT NULL, p_source text DEFAULT NULL, p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rows jsonb; v_total int;
BEGIN
  IF p_actor_id <> auth.uid() AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
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
$$;
REVOKE ALL ON FUNCTION public.get_accounting_journal(uuid, timestamptz, timestamptz, text, text, int, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_accounting_journal(uuid, timestamptz, timestamptz, text, text, int, int) TO authenticated, service_role;

-- Rapprochement : somme des mouvements WALLET du journal (par devise) vs delta réel du solde
-- wallet sur la période. Écart > 1 unité → anomalie Fatome 'accounting_gap'. La compta qui ne
-- colle pas au wallet est une compta qui ment.
CREATE OR REPLACE FUNCTION public.accounting_reconcile(
  p_actor_id uuid, p_from timestamptz DEFAULT now() - interval '30 days', p_to timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; v_flux numeric; v_gap numeric; v_out jsonb := '[]'::jsonb; v_dec int;
BEGIN
  IF p_actor_id <> auth.uid() AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  FOR r IN SELECT DISTINCT currency FROM public.wallets WHERE user_id = p_actor_id LOOP
    -- Flux net wallet du journal (recette − dépense, y compris trésorerie car le wallet, lui, bouge).
    SELECT COALESCE(SUM(CASE WHEN j.direction='recette' THEN j.amount ELSE -j.amount END), 0)
      INTO v_flux FROM public.accounting_journal j
    WHERE j.actor_id = p_actor_id AND j.source_table = 'wallet_transactions'
      AND j.currency = r.currency AND j.entry_at >= p_from AND j.entry_at <= p_to;
    -- (Le delta de solde exact demande un snapshot d'ouverture ; ici on expose le flux net wallet
    -- calculé, base du contrôle. Un écart entre ce flux et les mouvements réels wallet_transactions
    -- de la période est nul par construction — le contrôle DÉTECTE surtout un mapping manquant.)
    v_dec := public._ccy_decimals(r.currency);
    -- Vérif interne : le flux du journal doit égaler la somme nette des wallet_transactions bruts.
    SELECT COALESCE(SUM(CASE WHEN wt.receiver_user_id = p_actor_id THEN COALESCE(wt.net_amount, wt.amount)
                             WHEN wt.sender_user_id = p_actor_id THEN -(wt.amount + COALESCE(wt.fee,0)) ELSE 0 END), 0)
      INTO v_gap FROM public.wallet_transactions wt
    WHERE (wt.receiver_user_id = p_actor_id OR wt.sender_user_id = p_actor_id)
      AND wt.currency = r.currency AND wt.created_at >= p_from AND wt.created_at <= p_to;
    v_gap := round(v_flux - v_gap, v_dec);
    v_out := v_out || jsonb_build_object('currency', r.currency, 'journal_flux', v_flux, 'wallet_flux', v_flux - v_gap, 'gap', v_gap);
    IF abs(v_gap) > power(10, -v_dec) THEN
      PERFORM public.fatome_raise('accounting_gap', p_actor_id::text || ':' || r.currency, 'high',
        jsonb_build_object('actor', p_actor_id, 'currency', r.currency, 'gap', v_gap));
    END IF;
  END LOOP;
  RETURN jsonb_build_object('reconciliations', v_out);
END;
$$;
REVOKE ALL ON FUNCTION public.accounting_reconcile(uuid, timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accounting_reconcile(uuid, timestamptz, timestamptz) TO authenticated, service_role;
