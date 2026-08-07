-- ═══════════════════════════════════════════════════════════════════════════
-- ZONES — séparer le CŒUR de lecture de la GARDE d'accès.
-- La sonde anti-régression tourne en service_role (aucun auth.uid()) : elle butait sur
-- `is_admin_or_pdg()` et renvoyait « forbidden », c'est-à-dire un ÉCHEC qui n'en était pas un.
-- On extrait le cœur (`_zones_rates_core`, service_role uniquement) ; la RPC exposée au PDG
-- garde son contrôle de rôle et délègue. UNE seule implémentation : la sonde vérifie donc
-- exactement ce que l'écran affiche, sans copie de logique. Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public._zones_rates_core(p_pairs text[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pair text; v_from text; v_to text;
  v_rate numeric; v_src text; v_at timestamptz; v_dir text;
  v_margin numeric; v_fresh_h numeric; v_out jsonb := '[]'::jsonb;
BEGIN
  FOREACH v_pair IN ARRAY COALESCE(p_pairs, ARRAY[]::text[]) LOOP
    v_from := upper(split_part(replace(v_pair, '-', '/'), '/', 1));
    v_to   := upper(split_part(replace(v_pair, '-', '/'), '/', 2));
    v_rate := NULL; v_src := NULL; v_at := NULL; v_dir := NULL;

    SELECT r.rate, r.source, r.retrieved_at INTO v_rate, v_src, v_at
    FROM public.currency_exchange_rates r
    WHERE upper(r.from_currency) = v_from AND upper(r.to_currency) = v_to
    ORDER BY r.retrieved_at DESC LIMIT 1;
    IF v_rate IS NOT NULL THEN v_dir := 'direct'; END IF;

    IF v_rate IS NULL THEN
      SELECT 1 / NULLIF(r.rate, 0), r.source, r.retrieved_at INTO v_rate, v_src, v_at
      FROM public.currency_exchange_rates r
      WHERE upper(r.from_currency) = v_to AND upper(r.to_currency) = v_from AND r.rate <> 0
      ORDER BY r.retrieved_at DESC LIMIT 1;
      IF v_rate IS NOT NULL THEN v_dir := 'inverse'; END IF;
    END IF;

    v_margin := public.fx_effective_margin_fraction(v_pair);
    SELECT freshness_hours INTO v_fresh_h FROM public.fx_pair_config WHERE pair = v_pair;
    v_fresh_h := COALESCE(v_fresh_h, 24);

    v_out := v_out || jsonb_build_object(
      'pair', v_pair, 'rate', v_rate, 'source', v_src, 'direction', v_dir,
      'collected_at', v_at,
      'age_hours', CASE WHEN v_at IS NULL THEN NULL
                        ELSE round(extract(epoch from (now() - v_at)) / 3600.0, 2) END,
      'freshness_hours', v_fresh_h,
      'fresh', (v_at IS NOT NULL AND v_at > now() - make_interval(hours => v_fresh_h::int)),
      'margin_fraction', v_margin,
      'margin_percent', round(v_margin * 100, 2),
      'final_rate', CASE WHEN v_rate IS NULL THEN NULL
                         ELSE round(v_rate * (1 + v_margin), public._ccy_decimals(v_to)) END);
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._zones_rates_core(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._zones_rates_core(text[]) TO service_role;

-- La RPC exposée : garde de rôle + délégation (aucune logique dupliquée).
CREATE OR REPLACE FUNCTION public.pdg_monetary_zones_rates(p_pairs text[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN public._zones_rates_core(p_pairs);
END $$;
REVOKE ALL ON FUNCTION public.pdg_monetary_zones_rates(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pdg_monetary_zones_rates(text[]) TO authenticated, service_role;

-- La sonde interroge le CŒUR (même code que l'écran, sans la garde d'accès).
CREATE OR REPLACE FUNCTION public.fatome_probe_zones_live()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pairs text[] := ARRAY['XOF/GNF','XAF/GNF','NGN/GNF','KES/GNF','MAD/GNF','ZAR/GNF'];
  v_src_fresh int; v_panel_fresh int := 0; v_panel jsonb; v_p jsonb;
BEGIN
  SELECT count(*) INTO v_src_fresh
  FROM unnest(v_pairs) p
  WHERE EXISTS (
    SELECT 1 FROM public.currency_exchange_rates r
    WHERE r.retrieved_at > now() - interval '24 hours'
      AND ((upper(r.from_currency) = upper(split_part(p, '/', 1)) AND upper(r.to_currency) = upper(split_part(p, '/', 2)))
        OR (upper(r.to_currency)   = upper(split_part(p, '/', 1)) AND upper(r.from_currency) = upper(split_part(p, '/', 2)))));

  BEGIN
    v_panel := public._zones_rates_core(v_pairs);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'layer', 'rpc', 'error_code', SQLSTATE,
      'message', 'Lecture du panneau Zones impossible : ' || SQLERRM);
  END;

  FOR v_p IN SELECT * FROM jsonb_array_elements(COALESCE(v_panel, '[]'::jsonb)) LOOP
    IF (v_p->>'rate') IS NOT NULL THEN v_panel_fresh := v_panel_fresh + 1; END IF;
  END LOOP;

  IF v_src_fresh > 0 AND v_panel_fresh = 0 THEN
    RETURN jsonb_build_object('ok', false, 'layer', 'data', 'error_code', 'ZONES_PANEL_DEAD_SOURCE',
      'message', 'Le panneau Zones ne renvoie AUCUN taux alors que la source en contient '
                 || v_src_fresh || ' frais — branchement cassé (table morte ?)');
  END IF;
  IF v_src_fresh > v_panel_fresh THEN
    RETURN jsonb_build_object('ok', false, 'layer', 'data', 'error_code', 'ZONES_PANEL_PARTIAL',
      'message', 'Panneau Zones incomplet : ' || v_panel_fresh || '/' || v_src_fresh || ' paires servies');
  END IF;
  RETURN jsonb_build_object('ok', true, 'layer', 'data', 'error_code', 'ZONES_PANEL_OK',
    'message', v_panel_fresh || '/' || array_length(v_pairs, 1) || ' paires servies par la source vivante');
END $$;
REVOKE ALL ON FUNCTION public.fatome_probe_zones_live() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_probe_zones_live() TO authenticated, service_role;

COMMIT;
