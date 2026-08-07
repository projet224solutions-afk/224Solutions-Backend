-- ═══════════════════════════════════════════════════════════════════════════
-- FATOME FONCTIONNALITÉS — LES CONTRÔLES EXÉCUTABLES (8.1/8.4 invariants).
-- CHOIX DE SÉCURITÉ ASSUMÉ : la config d'une sonde NE PORTE JAMAIS de SQL arbitraire
-- (ce serait une injection par la table). Les invariants vivent ICI, en SQL, indexés par
-- probe_key ; une sonde « invariant » se contente de nommer sa clé. Ajouter un invariant =
-- un WHEN dans fatome_probe_check + une ligne dans le fichier manifeste (CI-gardé).
-- Les sondes de DISPONIBILITÉ sont GÉNÉRIQUES : elles vérifient l'existence réelle des
-- RPC/tables déclarées au manifeste (pg_proc/pg_class) → une feature mémorisée est
-- surveillée dès le jour 1, sans code sur mesure (8.6.2).
-- LECTURE SEULE sur tout ce qui touche l'argent. Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1) Upsert des sondes depuis les fichiers manifeste (versionnés + CI) ────
CREATE OR REPLACE FUNCTION public.fatome_probes_upsert(p_probes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_p jsonb; v_n int := 0;
BEGIN
  FOR v_p IN SELECT * FROM jsonb_array_elements(COALESCE(p_probes, '[]'::jsonb)) LOOP
    -- Une sonde dont la feature n'est pas au manifeste est IGNORÉE (FK + cohérence CI).
    IF EXISTS (SELECT 1 FROM public.fatome_feature_manifest WHERE feature_key = v_p->>'feature_key') THEN
      INSERT INTO public.fatome_feature_probes AS p (
        probe_key, feature_key, probe_kind, label, config, criticality, enabled, is_default)
      VALUES (
        v_p->>'probe_key', v_p->>'feature_key', COALESCE(v_p->>'probe_kind','availability'),
        v_p->>'label', COALESCE(v_p->'config','{}'::jsonb),
        COALESCE(v_p->>'criticality','normal'),
        COALESCE((v_p->>'enabled')::boolean, true),
        COALESCE((v_p->>'is_default')::boolean, false))
      ON CONFLICT (probe_key) DO UPDATE SET
        feature_key = EXCLUDED.feature_key, probe_kind = EXCLUDED.probe_kind,
        label = EXCLUDED.label, config = EXCLUDED.config,
        criticality = EXCLUDED.criticality, enabled = EXCLUDED.enabled,
        is_default = EXCLUDED.is_default;
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('upserted', v_n,
    'total', (SELECT count(*) FROM public.fatome_feature_probes));
END; $$;
REVOKE ALL ON FUNCTION public.fatome_probes_upsert(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_probes_upsert(jsonb) TO service_role;

-- Génère une sonde de DISPONIBILITÉ par défaut pour toute feature qui n'en a aucune (8.6.2).
CREATE OR REPLACE FUNCTION public.fatome_probes_ensure_default()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_m record; v_n int := 0;
BEGIN
  FOR v_m IN SELECT feature_key, label, criticality FROM public.fatome_feature_manifest m
             WHERE NOT EXISTS (SELECT 1 FROM public.fatome_feature_probes p WHERE p.feature_key = m.feature_key)
  LOOP
    INSERT INTO public.fatome_feature_probes (probe_key, feature_key, probe_kind, label, criticality, is_default)
    VALUES ('auto:' || v_m.feature_key, v_m.feature_key, 'availability',
            'Disponibilité (auto) — ' || v_m.label, v_m.criticality, true)
    ON CONFLICT (probe_key) DO NOTHING;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END; $$;
REVOKE ALL ON FUNCTION public.fatome_probes_ensure_default() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_probes_ensure_default() TO service_role;

-- ── 2) SONDE DE DISPONIBILITÉ générique : les RPC/tables du manifeste EXISTENT-elles ? ──
-- Détecte exactement ce qui a tué la caisse dans le scénario du prompt : une RPC supprimée
-- ou une table renommée par une migration.
CREATE OR REPLACE FUNCTION public.fatome_probe_availability(p_feature text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_m record; v_x text; v_missing_rpc text[] := '{}'; v_missing_tbl text[] := '{}'; v_missing_col text[] := '{}';
  v_parts text[];
BEGIN
  SELECT * INTO v_m FROM public.fatome_feature_manifest WHERE feature_key = p_feature;
  IF v_m.feature_key IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'layer', 'manifest', 'error_code', 'UNKNOWN_FEATURE',
      'message', 'Fonctionnalité absente du manifeste');
  END IF;

  FOR v_x IN SELECT jsonb_array_elements_text(v_m.rpcs) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc pr JOIN pg_namespace n ON n.oid = pr.pronamespace
                   WHERE n.nspname = 'public' AND pr.proname = v_x) THEN
      v_missing_rpc := array_append(v_missing_rpc, v_x);
    END IF;
  END LOOP;

  FOR v_x IN SELECT jsonb_array_elements_text(v_m.tables) LOOP
    -- Forme « table » ou « table.colonne » (invariant de schéma : la colonne utilisée existe).
    v_parts := string_to_array(v_x, '.');
    IF array_length(v_parts, 1) = 2 THEN
      IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                     WHERE table_schema = 'public' AND table_name = v_parts[1] AND column_name = v_parts[2]) THEN
        v_missing_col := array_append(v_missing_col, v_x);
      END IF;
    ELSIF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                      WHERE n.nspname = 'public' AND c.relname = v_x AND c.relkind IN ('r','v','m','p')) THEN
      v_missing_tbl := array_append(v_missing_tbl, v_x);
    END IF;
  END LOOP;

  IF array_length(v_missing_rpc,1) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'layer', 'rpc', 'error_code', '42883',
      'message', 'RPC absente : ' || array_to_string(v_missing_rpc, ', '), 'missing', to_jsonb(v_missing_rpc));
  END IF;
  IF array_length(v_missing_col,1) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'layer', 'data', 'error_code', '42703',
      'message', 'Colonne absente : ' || array_to_string(v_missing_col, ', '), 'missing', to_jsonb(v_missing_col));
  END IF;
  IF array_length(v_missing_tbl,1) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'layer', 'data', 'error_code', '42P01',
      'message', 'Table absente : ' || array_to_string(v_missing_tbl, ', '), 'missing', to_jsonb(v_missing_tbl));
  END IF;

  RETURN jsonb_build_object('ok', true, 'checked_rpcs', jsonb_array_length(v_m.rpcs),
    'checked_tables', jsonb_array_length(v_m.tables));
END; $$;
REVOKE ALL ON FUNCTION public.fatome_probe_availability(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_probe_availability(text) TO authenticated, service_role;

-- ── 3) INVARIANTS MÉTIER exécutables (la LOGIQUE que Claude et le PDG connaissent) ──
-- Chaque WHEN = un invariant vérifiable, en LECTURE SEULE, borné dans le temps.
CREATE OR REPLACE FUNCTION public.fatome_probe_check(p_probe_key text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_bad int; v_n int;
BEGIN
  CASE p_probe_key

    -- CAISSE POS : total = sous-total + taxes − remise (au centime), sur 7 j.
    WHEN 'inv:vendeur_physique.caisse_vente:total_coherent' THEN
      SELECT count(*) INTO v_bad FROM public.pos_sales
      WHERE created_at > now() - interval '7 days'
        AND COALESCE(subtotal,0) > 0
        AND abs(COALESCE(total_amount,0) - (COALESCE(subtotal,0) + COALESCE(tax_amount,0) - COALESCE(discount_total,0))) > 0.01;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_TOTAL',
        'message', CASE WHEN v_bad = 0 THEN 'Totaux caisse cohérents'
                        ELSE v_bad || ' vente(s) POS avec total ≠ sous-total + taxes − remise' END);

    -- STOCK : jamais négatif.
    WHEN 'inv:vendeur_physique.stock:jamais_negatif' THEN
      SELECT count(*) INTO v_bad FROM public.products WHERE COALESCE(stock_quantity, 0) < 0;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_STOCK',
        'message', CASE WHEN v_bad = 0 THEN 'Aucun stock négatif'
                        ELSE v_bad || ' produit(s) à stock NÉGATIF' END);

    -- COURSE TAXI : part chauffeur + commission = prix total (au franc), sur 7 j.
    WHEN 'inv:taxi.course_prix:partage_exact' THEN
      SELECT count(*) INTO v_bad FROM public.taxi_trips
      WHERE completed_at > now() - interval '7 days' AND status = 'completed'
        AND COALESCE(price_total, 0) > 0
        AND abs(COALESCE(driver_share,0) + COALESCE(platform_fee,0) - COALESCE(price_total,0)) > 1;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_SPLIT',
        'message', CASE WHEN v_bad = 0 THEN 'Partage des courses exact'
                        ELSE v_bad || ' course(s) où part chauffeur + commission ≠ prix' END);

    -- LISTING PROXIMITÉ : au moins un service actif visible (sinon la recherche est vide).
    WHEN 'inv:proximite.listing:non_vide' THEN
      SELECT count(*) INTO v_n FROM public.professional_services WHERE status = 'active';
      RETURN jsonb_build_object('ok', v_n > 0, 'layer', 'data', 'error_code', 'EMPTY_LISTING',
        'message', v_n || ' service(s) actif(s) listable(s)');

    -- DEVIS : un devis accepté a toujours un prix > 0.
    WHEN 'inv:proximite.devis:prix_positif' THEN
      SELECT count(*) INTO v_bad FROM public.service_quotes
      WHERE status IN ('accepted','paid','completed') AND COALESCE(total_amount, 0) <= 0;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_QUOTE',
        'message', CASE WHEN v_bad = 0 THEN 'Devis acceptés tous chiffrés'
                        ELSE v_bad || ' devis accepté(s) SANS prix' END);

    -- WALLET : aucun solde négatif (invariant d'argent absolu).
    WHEN 'inv:transversal.wallet:solde_positif' THEN
      SELECT count(*) INTO v_bad FROM public.wallets WHERE COALESCE(balance, 0) < 0;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_BALANCE',
        'message', CASE WHEN v_bad = 0 THEN 'Aucun wallet négatif'
                        ELSE v_bad || ' wallet(s) à solde NÉGATIF' END);

    -- ESCROW : un escrow libéré a toujours une date de libération.
    WHEN 'inv:marketplace.escrow:release_date' THEN
      SELECT count(*) INTO v_bad FROM public.escrow_transactions
      WHERE status = 'released' AND released_at IS NULL;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_ESCROW',
        'message', CASE WHEN v_bad = 0 THEN 'Libérations d''escrow datées'
                        ELSE v_bad || ' escrow libéré(s) sans date' END);

    -- COMMANDE : le total d'une commande payée est strictement positif.
    WHEN 'inv:marketplace.commande:total_positif' THEN
      SELECT count(*) INTO v_bad FROM public.orders
      WHERE created_at > now() - interval '7 days'
        AND COALESCE(payment_status,'') = 'paid' AND COALESCE(total_amount, 0) <= 0;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_ORDER',
        'message', CASE WHEN v_bad = 0 THEN 'Commandes payées toutes chiffrées'
                        ELSE v_bad || ' commande(s) payée(s) à total nul' END);

    -- LIVRAISON : une livraison terminée a un livreur assigné.
    WHEN 'inv:livreur.mission:livreur_assigne' THEN
      SELECT count(*) INTO v_bad FROM public.deliveries
      WHERE status = 'delivered' AND driver_id IS NULL;
      RETURN jsonb_build_object('ok', v_bad = 0, 'layer', 'data', 'error_code', 'INVARIANT_DELIVERY',
        'message', CASE WHEN v_bad = 0 THEN 'Livraisons terminées toutes assignées'
                        ELSE v_bad || ' livraison(s) terminée(s) SANS livreur' END);

    -- FX : au moins un taux GNF frais (< 24 h) — le cœur de toute conversion.
    WHEN 'inv:transversal.fx:taux_frais' THEN
      SELECT count(*) INTO v_n FROM public.currency_exchange_rates
      WHERE to_currency = 'GNF' AND retrieved_at > now() - interval '24 hours';
      RETURN jsonb_build_object('ok', v_n > 0, 'layer', 'external', 'error_code', 'FX_STALE',
        'message', v_n || ' taux →GNF de moins de 24 h');

    ELSE
      -- FAIL-CLOSED : une sonde invariant sans contrôle défini = INCONNU, jamais « OK ».
      RETURN jsonb_build_object('ok', false, 'layer', 'probe', 'error_code', 'NO_CHECK_DEFINED',
        'message', 'Aucun contrôle défini pour ' || p_probe_key);
  END CASE;
EXCEPTION WHEN OTHERS THEN
  -- Une erreur SQL (colonne/table disparue) EST le signal : on la remonte telle quelle.
  RETURN jsonb_build_object('ok', false, 'layer', 'rpc', 'error_code', SQLSTATE, 'message', SQLERRM);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_probe_check(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_probe_check(text) TO authenticated, service_role;

-- ── 4) ROUTES SERVIES vs MANIFESTE (filet d'exécution 8.6.3) ────────────────
CREATE TABLE IF NOT EXISTS public.fatome_route_traffic (
  route text PRIMARY KEY,
  hits bigint NOT NULL DEFAULT 0,
  first_seen timestamptz NOT NULL DEFAULT now(),
  last_seen timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.fatome_route_traffic ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS frt_read_pdg ON public.fatome_route_traffic;
CREATE POLICY frt_read_pdg ON public.fatome_route_traffic FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());

CREATE OR REPLACE FUNCTION public.fatome_route_seen(p_route text, p_hits int DEFAULT 1)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.fatome_route_traffic (route, hits) VALUES (p_route, GREATEST(COALESCE(p_hits,1),1))
  ON CONFLICT (route) DO UPDATE
    SET hits = fatome_route_traffic.hits + GREATEST(COALESCE(p_hits,1),1), last_seen = now();
END; $$;
REVOKE ALL ON FUNCTION public.fatome_route_seen(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_route_seen(text, int) TO service_role;

-- Routes qui reçoivent du trafic SANS entrée manifeste → anomalie feature_unregistered.
CREATE OR REPLACE FUNCTION public.fatome_unregistered_routes_check()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rows jsonb; v_n int; v_day text := to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD');
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object('route', t.route, 'hits', t.hits)), '[]'::jsonb), count(*)
  INTO v_rows, v_n
  FROM public.fatome_route_traffic t
  WHERE t.last_seen > now() - interval '24 hours'
    AND NOT EXISTS (
      SELECT 1 FROM public.fatome_feature_manifest m
      WHERE m.routes @> to_jsonb(t.route)::jsonb);

  IF v_n > 0 THEN
    PERFORM public.fatome_raise('feature:feature_unregistered',
      'monitor:feature_unregistered:' || v_day, 'high',
      jsonb_build_object('count', v_n, 'routes', v_rows));
  ELSE
    PERFORM public.fatome_resolve_type('feature:feature_unregistered');
  END IF;
  RETURN jsonb_build_object('unregistered', v_n, 'routes', v_rows);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_unregistered_routes_check() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_unregistered_routes_check() TO service_role;

COMMIT;
