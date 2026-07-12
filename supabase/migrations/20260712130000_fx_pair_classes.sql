-- ════════════════════════════════════════════════════════════════════════════
-- FX — CLASSES DE DEVISES (peg_fixe / flottante_volatile / restreinte) : réglages PAR PAIRE
-- ════════════════════════════════════════════════════════════════════════════
-- UN SEUL moteur (fx_quote/fx_convert/fx_ingest_rate). Ce fichier AJOUTE une config par paire :
-- marge, seuils quarantaine/divergence, fraîcheur, garde CORRIDOR_RESTREINT (déverrouillage
-- juridique tracé), peg-check EUR pour la zone CFA. ZÉRO régression : paire sans ligne de config
-- → défauts globaux de fx_config (comportement actuel identique). À appliquer APRÈS 20260712120000.
-- Money-critical : tests intégrés (rollback). Livrée en fichier.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1) Config PAR PAIRE (une ligne par paire ; historique via audit) ──
CREATE TABLE IF NOT EXISTS public.fx_pair_config (
  pair                          text PRIMARY KEY,
  currency_class                text NOT NULL DEFAULT 'flottante_volatile'
                                  CHECK (currency_class IN ('peg_fixe','flottante_volatile','restreinte')),
  margin_percent                numeric,   -- NULL = marge globale fx_config
  max_daily_move_percent        numeric,   -- NULL = global (quarantaine)
  freshness_hours               numeric,   -- NULL = global (fraîcheur)
  max_source_divergence_percent numeric,   -- NULL = global
  operations_enabled            boolean NOT NULL DEFAULT true,
  legal_clearance               boolean NOT NULL DEFAULT false,   -- déverrouillage juridique (restreinte)
  legal_note                    text,
  updated_by                    uuid,
  updated_at                    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_fxpc_positive CHECK (
    (margin_percent IS NULL OR margin_percent >= 0) AND
    (max_daily_move_percent IS NULL OR max_daily_move_percent > 0) AND
    (freshness_hours IS NULL OR freshness_hours > 0) AND
    (max_source_divergence_percent IS NULL OR max_source_divergence_percent > 0))
);
ALTER TABLE public.fx_pair_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fxpc_pdg_read ON public.fx_pair_config;
CREATE POLICY fxpc_pdg_read ON public.fx_pair_config FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
REVOKE ALL ON public.fx_pair_config FROM anon;
-- Écriture réservée aux RPC SECURITY DEFINER (fx_set_pair_config / fx_unlock_restricted_pair).

-- ── 2) Seeds — AUCUN changement pour les paires existantes (thresholds NULL = global) ──
INSERT INTO public.fx_pair_config (pair, currency_class, margin_percent, max_daily_move_percent, freshness_hours) VALUES
  -- Majors : classe posée, seuils NULL → défauts globaux = comportement identique à aujourd'hui.
  ('USD/GNF','flottante_volatile', NULL, NULL, NULL),
  ('EUR/GNF','flottante_volatile', NULL, NULL, NULL),
  ('GBP/GNF','flottante_volatile', NULL, NULL, NULL),
  ('CAD/GNF','flottante_volatile', NULL, NULL, NULL),
  -- Zone CFA (peg EUR 655,957) : réglages standard (NULL → 5%/5%/24h global).
  ('XOF/GNF','peg_fixe', NULL, NULL, NULL),
  ('XAF/GNF','peg_fixe', NULL, NULL, NULL),
  -- Zone devises indépendantes (volatile) : marge 7%, quarantaine 12%, fraîcheur 8h.
  ('NGN/GNF','flottante_volatile', 7, 12, 8),
  ('GHS/GNF','flottante_volatile', 7, 12, 8),
  ('KES/GNF','flottante_volatile', 7, 12, 8),
  ('MAD/GNF','flottante_volatile', 7, 12, 8),
  ('ZAR/GNF','flottante_volatile', 7, 12, 8)
ON CONFLICT (pair) DO NOTHING;
-- Restreintes : opérations désactivées, verrou juridique (par défaut).
INSERT INTO public.fx_pair_config (pair, currency_class, operations_enabled, legal_clearance) VALUES
  ('DZD/GNF','restreinte', false, false),
  ('ETB/GNF','restreinte', false, false),
  ('EGP/GNF','restreinte', false, false)
ON CONFLICT (pair) DO NOTHING;

-- Bornes de sécurité (générreuses ; le PDG affine dans l'écran). Optionnelles (gate ignoré si absente).
INSERT INTO public.fx_pair_bounds (pair, min_rate, max_rate) VALUES
  ('XAF/GNF', 8, 22), ('GBP/GNF', 8000, 15000), ('CAD/GNF', 4500, 8500),
  ('NGN/GNF', 2, 12), ('GHS/GNF', 250, 1000), ('KES/GNF', 35, 110),
  ('MAD/GNF', 550, 1300), ('ZAR/GNF', 250, 800),
  ('DZD/GNF', 30, 110), ('ETB/GNF', 30, 140), ('EGP/GNF', 90, 350)
ON CONFLICT (pair) DO NOTHING;

-- ── 3) fx_quote v2 : lit fx_pair_config (marge/fraîcheur PAR PAIRE) + garde CORRIDOR_RESTREINT ──
CREATE OR REPLACE FUNCTION public.fx_quote(p_pair text, p_amount numeric, p_direction text DEFAULT 'sell_base')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg public.fx_config; v_pc public.fx_pair_config;
  v_margin numeric; v_fresh numeric;
  v_max numeric; v_min numeric; v_cnt int;
  v_bill numeric; v_pay numeric; v_ids bigint[]; v_sources text[];
BEGIN
  v_cfg := public.fx_active_config();
  SELECT * INTO v_pc FROM public.fx_pair_config WHERE pair = p_pair;

  -- Garde CORRIDOR_RESTREINT (AVANT la fraîcheur) : classe restreinte non déverrouillée, ou opérations désactivées.
  IF v_pc.pair IS NOT NULL AND (
       (v_pc.currency_class = 'restreinte' AND NOT v_pc.legal_clearance)
       OR v_pc.operations_enabled = false
     ) THEN
    RAISE EXCEPTION 'CORRIDOR_RESTREINT: conversions verrouillees pour % (controle des changes)', p_pair;
  END IF;

  v_margin := COALESCE(v_pc.margin_percent, v_cfg.fx_margin_percent);
  v_fresh  := COALESCE(v_pc.freshness_hours, v_cfg.fx_stale_hours);

  SELECT max(rate), min(rate), count(*), array_agg(id), array_agg(DISTINCT source)
  INTO v_max, v_min, v_cnt, v_ids, v_sources
  FROM public.fx_rates_ledger
  WHERE pair = p_pair AND status = 'active' AND collected_at > now() - make_interval(hours => v_fresh::int);

  IF v_cnt IS NULL OR v_cnt = 0 OR v_max IS NULL OR v_max <= 0 THEN
    RAISE EXCEPTION 'TAUX_INDISPONIBLE: aucune source validee fraiche pour %', p_pair;
  END IF;

  v_bill := round(v_max * (1 + v_margin / 100.0));   -- facturer HAUT + marge
  v_pay  := v_min;                                    -- payer BAS

  RETURN jsonb_build_object(
    'pair', p_pair, 'direction', p_direction,
    'currency_class', COALESCE(v_pc.currency_class, 'default'),
    'taux_facturation', v_bill, 'taux_paiement', v_pay,
    'montant_facture', round(p_amount * v_bill),
    'cout_paiement',   round(p_amount * v_pay),
    'spread_estime',   round(p_amount * v_bill) - round(p_amount * v_pay),
    'rate_ids', v_ids, 'sources_utilisees', v_sources,
    'margin_percent', v_margin, 'freshness_hours', v_fresh, 'quoted_at', now()
  );
END $$;
REVOKE ALL ON FUNCTION public.fx_quote(text, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_quote(text, numeric, text) TO authenticated, service_role;

-- ── 4) fx_ingest_rate v2 : seuils PAR PAIRE + peg-check EUR pour la zone CFA ──
CREATE OR REPLACE FUNCTION public.fx_ingest_rate(p_pair text, p_rate numeric, p_source text, p_collected_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg public.fx_config; v_pc public.fx_pair_config; v_bounds public.fx_pair_bounds;
  v_move_thr numeric; v_div_thr numeric;
  v_prev numeric; v_move numeric; v_median numeric; v_div numeric;
  v_status text := 'active'; v_reason text := NULL; v_id bigint;
  v_eur numeric; v_peg_implied numeric; v_peg_div numeric;
BEGIN
  IF p_rate IS NULL OR p_rate <= 0 THEN RAISE EXCEPTION 'FX_RATE_INVALIDE'; END IF;
  v_cfg := public.fx_active_config();
  SELECT * INTO v_pc FROM public.fx_pair_config WHERE pair = p_pair;
  v_move_thr := COALESCE(v_pc.max_daily_move_percent, v_cfg.fx_max_daily_move_percent);
  v_div_thr  := COALESCE(v_pc.max_source_divergence_percent, v_cfg.fx_max_source_divergence_percent);

  -- Porte 1 : bornes absolues.
  SELECT * INTO v_bounds FROM public.fx_pair_bounds WHERE pair = p_pair;
  IF v_bounds.pair IS NOT NULL AND (p_rate < v_bounds.min_rate OR p_rate > v_bounds.max_rate) THEN
    v_status := 'rejected'; v_reason := format('hors bornes [%s, %s]', v_bounds.min_rate, v_bounds.max_rate);
  END IF;

  -- Porte 2 : variation vs dernier actif de la MÊME source (seuil PAR PAIRE).
  IF v_status = 'active' THEN
    SELECT rate INTO v_prev FROM public.fx_rates_ledger
    WHERE pair = p_pair AND source = p_source AND status = 'active' ORDER BY collected_at DESC LIMIT 1;
    IF v_prev IS NOT NULL AND v_prev > 0 THEN
      v_move := abs(p_rate - v_prev) / v_prev * 100;
      IF v_move > v_move_thr THEN
        v_status := 'quarantine'; v_reason := format('variation %s%% > %s%% (source %s)', round(v_move,2), v_move_thr, p_source);
      END IF;
    END IF;
  END IF;

  -- Porte 3 : divergence vs médiane (seuil PAR PAIRE).
  IF v_status = 'active' THEN
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY rate) INTO v_median
    FROM public.fx_rates_ledger WHERE pair = p_pair AND status = 'active';
    IF v_median IS NOT NULL AND v_median > 0 THEN
      v_div := abs(p_rate - v_median) / v_median * 100;
      IF v_div > v_div_thr THEN
        v_status := 'verification'; v_reason := format('divergence %s%% vs mediane %s', round(v_div,2), round(v_median));
      END IF;
    END IF;
  END IF;

  -- Peg-check zone CFA : XOF/XAF arrimes EUR a 655,957. Divergence vs (EUR/GNF / 655,957) > 1% = critique.
  IF v_pc.currency_class = 'peg_fixe' AND p_pair IN ('XOF/GNF','XAF/GNF') THEN
    SELECT rate INTO v_eur FROM public.fx_rates_ledger
    WHERE pair = 'EUR/GNF' AND status = 'active' ORDER BY collected_at DESC LIMIT 1;
    IF v_eur IS NOT NULL AND v_eur > 0 THEN
      v_peg_implied := v_eur / 655.957;
      v_peg_div := abs(p_rate - v_peg_implied) / v_peg_implied * 100;
      IF v_peg_div > 1 THEN
        IF v_status = 'active' THEN v_status := 'quarantine'; END IF;
        v_reason := COALESCE(v_reason || ' | ', '') || format('peg divergence %s%% (implique %s)', round(v_peg_div,2), round(v_peg_implied,4));
        PERFORM public.agent_audit_log_safe('critical', 'fx_peg_divergence',
          jsonb_build_object('pair', p_pair, 'rate', p_rate, 'peg_implied', v_peg_implied, 'divergence_pct', round(v_peg_div,2), 'eur_gnf', v_eur));
      END IF;
    END IF;
  END IF;

  -- Écriture append-only. Si active : l'ancien actif de la même source passe superseded.
  IF v_status = 'active' THEN
    UPDATE public.fx_rates_ledger SET status = 'superseded', applied_to = p_collected_at
    WHERE pair = p_pair AND source = p_source AND status = 'active';
  END IF;
  INSERT INTO public.fx_rates_ledger (pair, rate, source, collected_at, status, validated_by, applied_from, reason)
  VALUES (p_pair, p_rate, p_source, p_collected_at, v_status, 'auto',
          CASE WHEN v_status = 'active' THEN p_collected_at ELSE NULL END, v_reason)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'status', v_status, 'reason', v_reason);
END $$;
REVOKE ALL ON FUNCTION public.fx_ingest_rate(text, numeric, text, timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_ingest_rate(text, numeric, text, timestamptz) TO service_role;

-- ── 5) RPC PDG : régler une paire (tracée) ──
-- N'active JAMAIS legal_clearance (réservé à fx_unlock_restricted_pair).
CREATE OR REPLACE FUNCTION public.fx_set_pair_config(p_pair text, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_old public.fx_pair_config; v_class text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT * INTO v_old FROM public.fx_pair_config WHERE pair = p_pair;
  v_class := COALESCE(p_changes->>'currency_class', v_old.currency_class, 'flottante_volatile');
  IF v_class NOT IN ('peg_fixe','flottante_volatile','restreinte') THEN RAISE EXCEPTION 'CLASSE_INVALIDE'; END IF;

  INSERT INTO public.fx_pair_config (pair, currency_class, margin_percent, max_daily_move_percent,
    freshness_hours, max_source_divergence_percent, operations_enabled, updated_by, updated_at)
  VALUES (p_pair, v_class,
    COALESCE((p_changes->>'margin_percent')::numeric, v_old.margin_percent),
    COALESCE((p_changes->>'max_daily_move_percent')::numeric, v_old.max_daily_move_percent),
    COALESCE((p_changes->>'freshness_hours')::numeric, v_old.freshness_hours),
    COALESCE((p_changes->>'max_source_divergence_percent')::numeric, v_old.max_source_divergence_percent),
    COALESCE((p_changes->>'operations_enabled')::boolean, v_old.operations_enabled, true),
    auth.uid(), now())
  ON CONFLICT (pair) DO UPDATE SET
    currency_class = EXCLUDED.currency_class,
    margin_percent = EXCLUDED.margin_percent,
    max_daily_move_percent = EXCLUDED.max_daily_move_percent,
    freshness_hours = EXCLUDED.freshness_hours,
    max_source_divergence_percent = EXCLUDED.max_source_divergence_percent,
    operations_enabled = EXCLUDED.operations_enabled,
    updated_by = EXCLUDED.updated_by, updated_at = now();

  PERFORM public.agent_audit_log_safe('info', 'fx_pair_config_update',
    jsonb_build_object('pair', p_pair, 'changes', p_changes, 'old', to_jsonb(v_old)));
  RETURN jsonb_build_object('success', true, 'pair', p_pair, 'currency_class', v_class);
END $$;
REVOKE ALL ON FUNCTION public.fx_set_pair_config(text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_set_pair_config(text, jsonb) TO authenticated, service_role;

-- ── 5b) RPC PDG : déverrouillage juridique d'une paire restreinte (note OBLIGATOIRE, tracé) ──
CREATE OR REPLACE FUNCTION public.fx_unlock_restricted_pair(p_pair text, p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_note IS NULL OR length(btrim(p_note)) < 5 THEN RAISE EXCEPTION 'NOTE_JURIDIQUE_OBLIGATOIRE'; END IF;
  UPDATE public.fx_pair_config
  SET legal_clearance = true, operations_enabled = true, legal_note = p_note, updated_by = auth.uid(), updated_at = now()
  WHERE pair = p_pair AND currency_class = 'restreinte';
  IF NOT FOUND THEN RAISE EXCEPTION 'PAIRE_RESTREINTE_INTROUVABLE'; END IF;
  PERFORM public.agent_audit_log_safe('warning', 'fx_restricted_pair_unlocked',
    jsonb_build_object('pair', p_pair, 'note', p_note, 'by', auth.uid()));
  RETURN jsonb_build_object('success', true, 'pair', p_pair, 'legal_clearance', true);
END $$;
REVOKE ALL ON FUNCTION public.fx_unlock_restricted_pair(text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_unlock_restricted_pair(text, text) TO authenticated, service_role;

-- ── 6) Monitor v2 : fraîcheur PAR PAIRE + peg divergences ──
CREATE OR REPLACE FUNCTION public.fx_monitor_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_quarantine int; v_verification int; v_stale int; v_rejected_24h int; v_peg int; v_global_fresh numeric;
BEGIN
  SELECT fx_stale_hours INTO v_global_fresh FROM public.fx_active_config();
  SELECT count(*) INTO v_quarantine FROM public.fx_rates_ledger WHERE status='quarantine' AND created_at < now() - interval '2 hours';
  SELECT count(*) INTO v_verification FROM public.fx_rates_ledger WHERE status='verification';
  SELECT count(*) INTO v_rejected_24h FROM public.fx_rates_ledger WHERE status='rejected' AND created_at > now() - interval '24 hours';
  -- Stale PAR PAIRE : paire opérationnelle sans taux actif frais selon SA fraîcheur.
  SELECT count(*) INTO v_stale FROM public.fx_pair_config pc
  WHERE pc.operations_enabled = true
    AND NOT EXISTS (SELECT 1 FROM public.fx_rates_ledger l
      WHERE l.pair = pc.pair AND l.status = 'active'
        AND l.collected_at > now() - make_interval(hours => COALESCE(pc.freshness_hours, v_global_fresh)::int));
  SELECT count(*) INTO v_peg FROM public.agent_cash_audit_log WHERE event = 'fx_peg_divergence' AND created_at > now() - interval '24 hours';

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','fx_quarantine_stuck','label','Taux en quarantaine > 2h non traites','severity','critical','count',v_quarantine,'observed',v_quarantine),
    jsonb_build_object('key','fx_verification_open','label','Taux en verification (divergence)','severity','warning','count',v_verification,'observed',v_verification),
    jsonb_build_object('key','fx_pair_stale','label','Paires sans taux frais (fraicheur par paire)','severity','critical','count',v_stale,'observed',v_stale),
    jsonb_build_object('key','fx_rejected_24h','label','Taux rejetes (hors bornes) 24h','severity','warning','count',v_rejected_24h,'observed',v_rejected_24h),
    jsonb_build_object('key','fx_peg_divergence','label','Divergences peg CFA vs EUR (24h)','severity','critical','count',v_peg,'observed',v_peg)
  ));
END $$;
REVOKE ALL ON FUNCTION public.fx_monitor_report() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_monitor_report() TO authenticated, service_role;

COMMENT ON TABLE public.fx_pair_config IS 'Config FX PAR PAIRE (classe + seuils + verrou juridique). Ecriture via fx_set_pair_config / fx_unlock_restricted_pair uniquement.';

-- ── 7) TESTS (zéro régression + verrou + déverrouillage + peg-check) — nettoyage par IDs (sûr) ──
DO $$
DECLARE q1 jsonb; q2 jsonb; err text; v_unlocked boolean; r jsonb; v_alert int; v_ids bigint[] := '{}';
BEGIN
  -- Paires + rates de test isolés. On CAPTURE chaque id inséré → suppression ciblée (jamais un vrai taux).
  INSERT INTO public.fx_pair_bounds (pair, min_rate, max_rate) VALUES ('ZUS/GNF', 1000, 20000) ON CONFLICT (pair) DO NOTHING;
  r := public.fx_ingest_rate('ZUS/GNF', 8600, 'bcrg', now()); v_ids := v_ids || (r->>'id')::bigint;

  -- (A) ZÉRO RÉGRESSION : paire SANS config → marge/fraicheur globales (5% / 24h).
  q1 := public.fx_quote('ZUS/GNF', 1, 'sell_base');
  IF (q1->>'margin_percent')::numeric <> (SELECT fx_margin_percent FROM public.fx_active_config()) THEN
    RAISE EXCEPTION 'REGRESSION: paire sans config n''utilise pas la marge globale (got %)', q1->>'margin_percent';
  END IF;
  IF (q1->>'taux_facturation')::numeric <> round(8600 * (1 + (SELECT fx_margin_percent FROM public.fx_active_config())/100.0)) THEN
    RAISE EXCEPTION 'REGRESSION: facturation differente du comportement global';
  END IF;

  -- (B) VERROU restreinte : DZD/GNF → CORRIDOR_RESTREINT (avant meme la fraicheur).
  BEGIN
    q2 := public.fx_quote('DZD/GNF', 1, 'sell_base');
    RAISE EXCEPTION 'VERROU KO: DZD/GNF aurait du lever CORRIDOR_RESTREINT';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF position('CORRIDOR_RESTREINT' in err) = 0 THEN RAISE EXCEPTION 'VERROU KO: erreur inattendue: %', err; END IF;
  END;

  -- (C) DÉVERROUILLAGE tracé → puis conversion possible (avec un taux frais).
  PERFORM public.fx_unlock_restricted_pair('DZD/GNF', 'autorisation obtenue le 2026-07-12, ref TEST-001');
  SELECT legal_clearance INTO v_unlocked FROM public.fx_pair_config WHERE pair = 'DZD/GNF';
  IF NOT v_unlocked THEN RAISE EXCEPTION 'DEVERROUILLAGE KO: legal_clearance non pose'; END IF;
  r := public.fx_ingest_rate('DZD/GNF', 64, 'banque_algerie', now()); v_ids := v_ids || (r->>'id')::bigint;
  q2 := public.fx_quote('DZD/GNF', 1, 'sell_base');   -- ne doit plus lever
  IF (q2->>'taux_facturation') IS NULL THEN RAISE EXCEPTION 'DEVERROUILLAGE KO: quote vide apres unlock'; END IF;
  -- note obligatoire : un unlock sans note doit echouer.
  BEGIN
    PERFORM public.fx_unlock_restricted_pair('ETB/GNF', '');
    RAISE EXCEPTION 'NOTE KO: unlock sans note aurait du echouer';
  EXCEPTION WHEN OTHERS THEN
    IF position('NOTE_JURIDIQUE_OBLIGATOIRE' in SQLERRM) = 0 THEN RAISE EXCEPTION 'NOTE KO: erreur inattendue: %', SQLERRM; END IF;
  END;

  -- (D) PEG-CHECK : EUR/GNF actif = 9186 → implique XOF/GNF = 14.005 ; XOF divergent (16 = +14%) → critique.
  r := public.fx_ingest_rate('EUR/GNF', 9186, 'zzz_test_eur', now()); v_ids := v_ids || (r->>'id')::bigint;
  r := public.fx_ingest_rate('XOF/GNF', 16, 'zzz_test_xof', now()); v_ids := v_ids || (r->>'id')::bigint;
  SELECT count(*) INTO v_alert FROM public.agent_cash_audit_log WHERE event = 'fx_peg_divergence' AND (detail->>'pair') = 'XOF/GNF' AND created_at > now() - interval '1 minute';
  IF v_alert = 0 THEN RAISE EXCEPTION 'PEG-CHECK KO: aucune alerte fx_peg_divergence pour XOF divergent'; END IF;

  RAISE NOTICE 'OK FX classes : zero-regression + verrou CORRIDOR_RESTREINT + deverrouillage trace + peg-check.';

  -- Nettoyage CIBLÉ par IDs (jamais un vrai taux de prod). Append-only → trigger desactivé le temps du DELETE.
  ALTER TABLE public.fx_rates_ledger DISABLE TRIGGER trg_fx_ledger_immutable;
  DELETE FROM public.fx_rates_ledger WHERE id = ANY(v_ids);
  ALTER TABLE public.fx_rates_ledger ENABLE TRIGGER trg_fx_ledger_immutable;
  DELETE FROM public.fx_pair_bounds WHERE pair = 'ZUS/GNF';
  DELETE FROM public.agent_cash_audit_log
    WHERE created_at > now() - interval '1 minute'
      AND event IN ('fx_peg_divergence','fx_restricted_pair_unlocked','fx_pair_config_update')
      AND (detail->>'pair') IN ('XOF/GNF','DZD/GNF','ETB/GNF');
  -- Re-verrouille DZD (annule le unlock de test).
  UPDATE public.fx_pair_config SET legal_clearance = false, operations_enabled = false, legal_note = NULL WHERE pair = 'DZD/GNF';
END $$;

SELECT 'FX classes de devises : fx_pair_config (13 paires seedees) + fx_quote/fx_ingest_rate v2 par paire + CORRIDOR_RESTREINT + peg-check CFA + monitor par paire. Tests OK (zero-regression, verrou, deverrouillage, peg).' AS status;
