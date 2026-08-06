-- ═══════════════════════════════════════════════════════════════════════════
-- CONSOLE COMPTA PDG — rollup matérialisé (pays × type × acteur × devise × catégorie × jour).
-- Le PDG ne scanne JAMAIS la vue UNION live : les vues monde/pays lisent le rollup.
-- Rafraîchi par job leader-gardé (idempotent DELETE+INSERT). Montants PAR DEVISE (le pays
-- est un axe d'analyse, JAMAIS une conversion). Migration NOUVELLE (socle non modifié).
-- ═══════════════════════════════════════════════════════════════════════════

-- Pays d'un acteur : profil (country_code) → detected_country → 'GN' par défaut.
-- (Le verrou devise est porté par profiles.country_locked/country_code — même source.)
CREATE OR REPLACE FUNCTION public.accounting_actor_country(p_actor_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT upper(COALESCE(NULLIF(btrim(p.country_code), ''), NULLIF(btrim(p.detected_country), ''), 'GN'))
  FROM public.profiles p WHERE p.id = p_actor_id;
$$;

-- Type d'un acteur (déterministe, par existence de fiche). Priorité : chauffeur > livreur >
-- restaurant > prestataire > commerçant > autre.
CREATE OR REPLACE FUNCTION public.accounting_actor_type(p_actor_id uuid)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.taxi_drivers WHERE user_id = p_actor_id) THEN RETURN 'taxi_moto'; END IF;
  IF EXISTS (SELECT 1 FROM public.drivers WHERE user_id = p_actor_id) THEN RETURN 'livreur'; END IF;
  IF EXISTS (SELECT 1 FROM public.professional_services ps JOIN public.service_types st ON st.id = ps.service_type_id
             WHERE ps.user_id = p_actor_id AND st.code = 'restaurant') THEN RETURN 'restaurant'; END IF;
  IF EXISTS (SELECT 1 FROM public.professional_services WHERE user_id = p_actor_id) THEN RETURN 'prestataire'; END IF;
  IF EXISTS (SELECT 1 FROM public.vendors WHERE user_id = p_actor_id) THEN RETURN 'commercant'; END IF;
  RETURN 'autre';
END;
$$;

-- Rollup quotidien granularité ACTEUR (permet toutes les agrégations au-dessus).
CREATE TABLE IF NOT EXISTS public.accounting_daily_rollup (
  day date NOT NULL,
  country_code text NOT NULL,
  actor_type text NOT NULL,
  actor_id uuid NOT NULL,
  currency text NOT NULL,
  category_code text NOT NULL,
  direction text NOT NULL,
  total numeric NOT NULL,
  n int NOT NULL,
  PRIMARY KEY (day, actor_id, currency, category_code, direction)
);
CREATE INDEX IF NOT EXISTS idx_rollup_country_type_day ON public.accounting_daily_rollup (country_code, actor_type, day);
CREATE INDEX IF NOT EXISTS idx_rollup_actor_day ON public.accounting_daily_rollup (actor_id, day);
ALTER TABLE public.accounting_daily_rollup ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rollup_pdg_read ON public.accounting_daily_rollup;
CREATE POLICY rollup_pdg_read ON public.accounting_daily_rollup FOR SELECT TO authenticated USING (public.is_admin_or_pdg());

-- Rafraîchissement IDEMPOTENT (DELETE+INSERT sur la fenêtre, jamais d'incrément). service_role.
CREATE OR REPLACE FUNCTION public.accounting_rollup_refresh(
  p_from date DEFAULT (now() - interval '7 days')::date, p_to date DEFAULT now()::date)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n int;
BEGIN
  DELETE FROM public.accounting_daily_rollup WHERE day >= p_from AND day <= p_to;
  INSERT INTO public.accounting_daily_rollup (day, country_code, actor_type, actor_id, currency, category_code, direction, total, n)
  SELECT g.day, public.accounting_actor_country(g.actor_id), public.accounting_actor_type(g.actor_id),
    g.actor_id, g.currency, g.category_code, g.direction, g.total, g.n
  FROM (
    SELECT j.entry_at::date AS day, j.actor_id, j.currency, j.category_code, j.direction,
      SUM(j.amount) AS total, count(*) AS n
    FROM public.accounting_journal j
    WHERE j.actor_id IS NOT NULL AND j.entry_at::date >= p_from AND j.entry_at::date <= p_to
    GROUP BY 1,2,3,4,5
  ) g;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.accounting_rollup_refresh(date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.accounting_rollup_refresh(date, date) TO service_role;

-- ── RPC console PDG (toutes : is_admin_or_pdg obligatoire) ───────────────────
CREATE OR REPLACE FUNCTION public.pdg_accounting_overview(
  p_from date DEFAULT (now()-interval '30 days')::date, p_to date DEFAULT now()::date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v jsonb;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT COALESCE(jsonb_agg(row_to_json(z)), '[]'::jsonb) INTO v FROM (
    SELECT r.country_code, r.currency,
      SUM(CASE WHEN r.direction='recette' THEN r.total ELSE 0 END) AS recettes,
      SUM(CASE WHEN r.direction='depense' THEN r.total ELSE 0 END) AS depenses,
      SUM(CASE WHEN c.affects_result AND r.direction='recette' THEN r.total
              WHEN c.affects_result AND r.direction='depense' THEN -r.total ELSE 0 END) AS resultat,
      count(DISTINCT r.actor_id) AS acteurs
    FROM public.accounting_daily_rollup r JOIN public.accounting_categories c ON c.code = r.category_code
    WHERE r.day >= p_from AND r.day <= p_to
    GROUP BY r.country_code, r.currency ORDER BY r.country_code, r.currency
  ) z;
  RETURN jsonb_build_object('overview', v);
END;
$$;
REVOKE ALL ON FUNCTION public.pdg_accounting_overview(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pdg_accounting_overview(date, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.pdg_accounting_by_actor_type(
  p_country text, p_from date DEFAULT (now()-interval '30 days')::date, p_to date DEFAULT now()::date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v jsonb;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT COALESCE(jsonb_agg(row_to_json(z)), '[]'::jsonb) INTO v FROM (
    SELECT r.actor_type, r.currency,
      SUM(CASE WHEN r.direction='recette' THEN r.total ELSE 0 END) AS recettes,
      SUM(CASE WHEN r.direction='depense' THEN r.total ELSE 0 END) AS depenses,
      SUM(CASE WHEN c.affects_result AND r.direction='recette' THEN r.total
              WHEN c.affects_result AND r.direction='depense' THEN -r.total ELSE 0 END) AS resultat,
      SUM(CASE WHEN r.category_code='frais_plateforme' THEN r.total ELSE 0 END) AS frais_plateforme,
      count(DISTINCT r.actor_id) AS acteurs
    FROM public.accounting_daily_rollup r JOIN public.accounting_categories c ON c.code = r.category_code
    WHERE r.country_code = upper(p_country) AND r.day >= p_from AND r.day <= p_to
    GROUP BY r.actor_type, r.currency ORDER BY resultat DESC
  ) z;
  RETURN jsonb_build_object('by_actor_type', v);
END;
$$;
REVOKE ALL ON FUNCTION public.pdg_accounting_by_actor_type(text, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pdg_accounting_by_actor_type(text, date, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.pdg_accounting_actors(
  p_country text, p_type text, p_from date DEFAULT (now()-interval '30 days')::date, p_to date DEFAULT now()::date,
  p_search text DEFAULT NULL, p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v jsonb; v_total int;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  WITH agg AS (
    SELECT r.actor_id,
      SUM(CASE WHEN r.direction='recette' THEN r.total ELSE 0 END) AS recettes,
      SUM(CASE WHEN r.direction='depense' THEN r.total ELSE 0 END) AS depenses,
      SUM(CASE WHEN c.affects_result AND r.direction='recette' THEN r.total
              WHEN c.affects_result AND r.direction='depense' THEN -r.total ELSE 0 END) AS resultat,
      max(r.day) AS derniere_activite
    FROM public.accounting_daily_rollup r JOIN public.accounting_categories c ON c.code = r.category_code
    WHERE r.country_code = upper(p_country) AND r.actor_type = p_type AND r.day >= p_from AND r.day <= p_to
    GROUP BY r.actor_id
  ), named AS (
    SELECT a.*, COALESCE(NULLIF(btrim(concat(p.first_name,' ',p.last_name)),''), p.email, a.actor_id::text) AS nom,
      EXISTS(SELECT 1 FROM public.fatome_anomalies fa WHERE fa.anomaly_type='accounting_gap'
             AND fa.ref LIKE a.actor_id::text || '%' AND NOT fa.resolved) AS a_un_ecart
    FROM agg a LEFT JOIN public.profiles p ON p.id = a.actor_id
    WHERE p_search IS NULL OR btrim(coalesce(p.first_name,'')||' '||coalesce(p.last_name,'')||' '||coalesce(p.email,'')) ILIKE '%'||p_search||'%'
  )
  , counted AS (SELECT count(*)::int AS total FROM named),
  paged AS (SELECT * FROM named ORDER BY resultat DESC LIMIT greatest(1,least(p_limit,200)) OFFSET greatest(0,p_offset))
  SELECT jsonb_build_object('total', (SELECT total FROM counted),
    'actors', COALESCE((SELECT jsonb_agg(row_to_json(paged)) FROM paged), '[]'::jsonb)) INTO v;
  RETURN v;
END;
$$;
REVOKE ALL ON FUNCTION public.pdg_accounting_actors(text, text, date, date, text, int, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pdg_accounting_actors(text, text, date, date, text, int, int) TO authenticated, service_role;

-- Cœur du rapprochement SANS gate (service_role) : le sweep nocturne l'appelle (auth.uid() NULL).
CREATE OR REPLACE FUNCTION public._accounting_reconcile_core(
  p_actor_id uuid, p_from timestamptz, p_to timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $core$
DECLARE r record; v_journal numeric; v_balance_delta numeric; v_gap numeric; v_dec int; v_out jsonb := '[]'::jsonb;
BEGIN
  FOR r IN SELECT DISTINCT currency FROM public.wallets WHERE user_id = p_actor_id LOOP
    v_dec := public._ccy_decimals(r.currency);
    SELECT COALESCE(SUM(CASE WHEN j.direction='recette' THEN j.amount ELSE -j.amount END), 0)
      INTO v_journal FROM public.accounting_journal j
    WHERE j.actor_id = p_actor_id AND j.source_table = 'wallet_transactions'
      AND j.currency = r.currency AND j.entry_at >= p_from AND j.entry_at <= p_to;
    SELECT COALESCE(SUM(delta), 0) INTO v_balance_delta FROM public.wallet_balance_audit
    WHERE user_id = p_actor_id AND currency = r.currency AND changed_at >= p_from AND changed_at <= p_to;
    v_gap := round(v_journal - v_balance_delta, v_dec);
    v_out := v_out || jsonb_build_object('currency', r.currency, 'journal_flux', v_journal,
      'balance_delta', v_balance_delta, 'gap', v_gap, 'ok', abs(v_gap) <= power(10, -v_dec));
    IF abs(v_gap) > power(10, -v_dec) THEN
      PERFORM public.fatome_raise('accounting_gap',
        p_actor_id::text || ':' || r.currency || ':' || to_char(p_to, 'YYYY-MM-DD'), 'high',
        jsonb_build_object('actor', p_actor_id, 'currency', r.currency,
          'journal_flux', v_journal, 'balance_delta', v_balance_delta, 'gap', v_gap));
    END IF;
  END LOOP;
  RETURN jsonb_build_object('reconciliations', v_out);
END;
$core$;
REVOKE ALL ON FUNCTION public._accounting_reconcile_core(uuid, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._accounting_reconcile_core(uuid, timestamptz, timestamptz) TO service_role;

-- Wrapper PDG-gated (l'acteur n'y accède plus — CH2) qui délègue au cœur.
CREATE OR REPLACE FUNCTION public.accounting_reconcile(
  p_actor_id uuid, p_from timestamptz DEFAULT now() - interval '30 days', p_to timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $wrap$
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN public._accounting_reconcile_core(p_actor_id, p_from, p_to);
END;
$wrap$;

-- Balayage de rapprochement (échantillon : les acteurs les plus actifs) → anomalies Fatome.
CREATE OR REPLACE FUNCTION public.pdg_accounting_reconcile_sweep(
  p_from date DEFAULT (now()-interval '7 days')::date, p_to date DEFAULT now()::date, p_sample int DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; v_checked int := 0; v_gaps int := 0; v_res jsonb;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  FOR r IN
    SELECT actor_id FROM public.accounting_daily_rollup
    WHERE day >= p_from AND day <= p_to GROUP BY actor_id
    ORDER BY SUM(total) DESC LIMIT greatest(1, least(p_sample, 500))
  LOOP
    v_res := public._accounting_reconcile_core(r.actor_id, p_from::timestamptz, (p_to + 1)::timestamptz);
    v_checked := v_checked + 1;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_res->'reconciliations') e WHERE (e->>'ok')::boolean = false) THEN
      v_gaps := v_gaps + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('checked', v_checked, 'with_gap', v_gaps);
END;
$$;
REVOKE ALL ON FUNCTION public.pdg_accounting_reconcile_sweep(date, date, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pdg_accounting_reconcile_sweep(date, date, int) TO service_role;
