-- ════════════════════════════════════════════════════════════════════════════
-- SYSTÈME FX — ledger des taux append-only + portes de validation + moteur directionnel
-- ════════════════════════════════════════════════════════════════════════════
-- Règle d'or PDG : FACTURER au taux le plus HAUT (MAX sources validées × (1+marge)),
-- PAYER au taux le plus BAS (MIN sources validées). Le spread → wallet PDG (fx_spread_revenue).
--
-- SOCLE ADDITIF (ce fichier) : tables + portes + fx_quote/fx_convert + fx_monitor_report + tests.
-- NE CÂBLE PAS les RPC d'argent live (credit_user_wallet_safe, create_order_core, agent cash…) :
-- STOP (b) — logique money non triviale + sentinelles anti-régression → rewiring = chantier staging
-- séparé. Source canonique confirmée = currency_exchange_rates (les scrapers alimenteront fx_ingest_rate).
-- Money-critical : TESTER EN STAGING. Livrée en fichier, non exécutée. Append-only, idempotent.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1) Config FX versionnée (1 ligne active) ──
CREATE TABLE IF NOT EXISTS public.fx_config (
  id                              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fx_margin_percent               numeric NOT NULL DEFAULT 5,   -- marge appliquée au taux de facturation
  fx_agent_withdrawal_fee_percent numeric NOT NULL DEFAULT 1,   -- commission plateforme retrait agent cross-devise
  fx_max_daily_move_percent       numeric NOT NULL DEFAULT 5,   -- variation max vs dernier actif même source → quarantaine
  fx_max_source_divergence_percent numeric NOT NULL DEFAULT 3,  -- écart max vs médiane → vérification
  fx_stale_hours                  numeric NOT NULL DEFAULT 24,  -- fraîcheur max d'un taux appliqué
  is_active                       boolean NOT NULL DEFAULT true,
  created_at                      timestamptz NOT NULL DEFAULT now(),
  created_by                      uuid,
  CONSTRAINT ck_fx_config_positive CHECK (fx_margin_percent >= 0 AND fx_agent_withdrawal_fee_percent >= 0
    AND fx_max_daily_move_percent > 0 AND fx_max_source_divergence_percent > 0 AND fx_stale_hours > 0)
);
ALTER TABLE public.fx_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fxc_pdg_all ON public.fx_config;
CREATE POLICY fxc_pdg_all ON public.fx_config FOR ALL TO authenticated USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());
REVOKE ALL ON public.fx_config FROM anon;
CREATE UNIQUE INDEX IF NOT EXISTS uq_fx_config_active ON public.fx_config (is_active) WHERE is_active = true;
INSERT INTO public.fx_config (is_active) SELECT true WHERE NOT EXISTS (SELECT 1 FROM public.fx_config WHERE is_active = true);

CREATE OR REPLACE FUNCTION public.fx_active_config() RETURNS public.fx_config
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM public.fx_config WHERE is_active = true ORDER BY created_at DESC LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.fx_active_config() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_active_config() TO authenticated, service_role;

-- ── 2) Bornes absolues par paire (éditables PDG) ──
CREATE TABLE IF NOT EXISTS public.fx_pair_bounds (
  pair      text PRIMARY KEY,            -- ex. 'USD/GNF'
  min_rate  numeric NOT NULL,
  max_rate  numeric NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  CONSTRAINT ck_fx_bounds CHECK (max_rate > min_rate AND min_rate > 0)
);
ALTER TABLE public.fx_pair_bounds ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fxb_pdg_all ON public.fx_pair_bounds;
CREATE POLICY fxb_pdg_all ON public.fx_pair_bounds FOR ALL TO authenticated USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());
REVOKE ALL ON public.fx_pair_bounds FROM anon;
-- Seeds prudents (le PDG affinera dans l'écran Taux) :
INSERT INTO public.fx_pair_bounds (pair, min_rate, max_rate) VALUES
  ('USD/GNF', 7000, 12000), ('EUR/GNF', 8000, 13000), ('XOF/GNF', 12, 20)
ON CONFLICT (pair) DO NOTHING;

-- ── 3) Ledger des taux — APPEND-ONLY ──
CREATE TABLE IF NOT EXISTS public.fx_rates_ledger (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pair         text NOT NULL,                 -- 'USD/GNF'
  rate         numeric NOT NULL CHECK (rate > 0),
  source       text NOT NULL,                 -- 'bcrg'|'bceao'|'ecobank'|...
  collected_at timestamptz NOT NULL DEFAULT now(),
  status       text NOT NULL DEFAULT 'verification'
                 CHECK (status IN ('active','quarantine','verification','rejected','superseded')),
  validated_by text,                          -- null | 'auto' | user_id (texte)
  applied_from timestamptz,
  applied_to   timestamptz,
  reason       text,
  created_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.fx_rates_ledger ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fxl_pdg_read ON public.fx_rates_ledger;
CREATE POLICY fxl_pdg_read ON public.fx_rates_ledger FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
REVOKE ALL ON public.fx_rates_ledger FROM anon;
-- Pas de policy INSERT/UPDATE/DELETE → seul le service_role (SECURITY DEFINER) écrit.
CREATE INDEX IF NOT EXISTS ix_fxl_pair_status ON public.fx_rates_ledger (pair, status, collected_at DESC);
CREATE INDEX IF NOT EXISTS ix_fxl_pair_source ON public.fx_rates_ledger (pair, source, collected_at DESC);

-- Trigger APPEND-ONLY : interdit toute modification des colonnes de VALEUR ; seul le statut/validation
-- peut évoluer (via les fonctions dédiées). DELETE totalement interdit.
CREATE OR REPLACE FUNCTION public.fx_ledger_immutable() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'fx_rates_ledger: DELETE interdit (append-only)'; END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.pair <> OLD.pair OR NEW.rate <> OLD.rate OR NEW.source <> OLD.source
       OR NEW.collected_at <> OLD.collected_at OR NEW.created_at <> OLD.created_at THEN
      RAISE EXCEPTION 'fx_rates_ledger: colonnes de valeur immuables (append-only)';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_fx_ledger_immutable ON public.fx_rates_ledger;
CREATE TRIGGER trg_fx_ledger_immutable BEFORE UPDATE OR DELETE ON public.fx_rates_ledger
  FOR EACH ROW EXECUTE FUNCTION public.fx_ledger_immutable();

-- ── 4) Portes de validation à l'ingestion ──
-- bornes → rejected ; variation > max_daily_move → quarantine ; divergence > max → verification ; sinon active.
CREATE OR REPLACE FUNCTION public.fx_ingest_rate(p_pair text, p_rate numeric, p_source text, p_collected_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg public.fx_config; v_bounds public.fx_pair_bounds;
  v_prev numeric; v_move numeric; v_median numeric; v_div numeric;
  v_status text := 'active'; v_reason text := NULL; v_id bigint;
BEGIN
  IF p_rate IS NULL OR p_rate <= 0 THEN RAISE EXCEPTION 'FX_RATE_INVALIDE'; END IF;
  v_cfg := public.fx_active_config();

  -- Porte 1 : bornes absolues.
  SELECT * INTO v_bounds FROM public.fx_pair_bounds WHERE pair = p_pair;
  IF v_bounds.pair IS NOT NULL AND (p_rate < v_bounds.min_rate OR p_rate > v_bounds.max_rate) THEN
    v_status := 'rejected'; v_reason := format('hors bornes [%s, %s]', v_bounds.min_rate, v_bounds.max_rate);
  END IF;

  -- Porte 2 : variation vs dernier actif de la MÊME source.
  IF v_status = 'active' THEN
    SELECT rate INTO v_prev FROM public.fx_rates_ledger
    WHERE pair = p_pair AND source = p_source AND status = 'active' ORDER BY collected_at DESC LIMIT 1;
    IF v_prev IS NOT NULL AND v_prev > 0 THEN
      v_move := abs(p_rate - v_prev) / v_prev * 100;
      IF v_move > v_cfg.fx_max_daily_move_percent THEN
        v_status := 'quarantine'; v_reason := format('variation %.2f%% > %s%% (source %s)', v_move, v_cfg.fx_max_daily_move_percent, p_source);
      END IF;
    END IF;
  END IF;

  -- Porte 3 : divergence vs médiane des sources actives de la paire.
  IF v_status = 'active' THEN
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY rate) INTO v_median
    FROM public.fx_rates_ledger WHERE pair = p_pair AND status = 'active';
    IF v_median IS NOT NULL AND v_median > 0 THEN
      v_div := abs(p_rate - v_median) / v_median * 100;
      IF v_div > v_cfg.fx_max_source_divergence_percent THEN
        v_status := 'verification'; v_reason := format('divergence %.2f%% vs médiane %s', v_div, round(v_median));
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

-- Saisie manuelle PDG (tracée) — passe QUAND MÊME les portes.
CREATE OR REPLACE FUNCTION public.fx_manual_rate_entry(p_pair text, p_rate numeric, p_source text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_res jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  v_res := public.fx_ingest_rate(p_pair, p_rate, COALESCE(p_source, 'manual'), now());
  UPDATE public.fx_rates_ledger SET validated_by = COALESCE(auth.uid()::text, 'pdg') WHERE id = (v_res->>'id')::bigint;
  RETURN v_res;
END $$;
REVOKE ALL ON FUNCTION public.fx_manual_rate_entry(text, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_manual_rate_entry(text, numeric, text) TO authenticated, service_role;

-- Validation PDG d'une quarantaine / vérification.
CREATE OR REPLACE FUNCTION public.fx_validate_quarantined(p_id bigint, p_action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.fx_rates_ledger;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_action NOT IN ('approve','reject') THEN RAISE EXCEPTION 'ACTION_INVALIDE'; END IF;
  SELECT * INTO v_row FROM public.fx_rates_ledger WHERE id = p_id FOR UPDATE;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'INTROUVABLE'; END IF;
  IF v_row.status NOT IN ('quarantine','verification') THEN RAISE EXCEPTION 'DEJA_TRAITE'; END IF;

  IF p_action = 'approve' THEN
    UPDATE public.fx_rates_ledger SET status = 'superseded', applied_to = now()
    WHERE pair = v_row.pair AND source = v_row.source AND status = 'active';
    UPDATE public.fx_rates_ledger SET status = 'active', validated_by = COALESCE(auth.uid()::text, 'pdg'), applied_from = now()
    WHERE id = p_id;
  ELSE
    UPDATE public.fx_rates_ledger SET status = 'rejected', validated_by = COALESCE(auth.uid()::text, 'pdg') WHERE id = p_id;
  END IF;
  RETURN jsonb_build_object('id', p_id, 'action', p_action);
END $$;
REVOKE ALL ON FUNCTION public.fx_validate_quarantined(bigint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_validate_quarantined(bigint, text) TO authenticated, service_role;

-- ── 5) Moteur directionnel : fx_quote (lecture seule) ──
-- Renvoie taux_facturation (MAX validés × (1+marge)), taux_paiement (MIN validés), montants, spread.
-- Sources VALIDÉES = status 'active' ET fraîches (< fx_stale_hours). Aucune → TAUX_INDISPONIBLE.
CREATE OR REPLACE FUNCTION public.fx_quote(p_pair text, p_amount numeric, p_direction text DEFAULT 'sell_base')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg public.fx_config; v_max numeric; v_min numeric; v_cnt int;
  v_bill numeric; v_pay numeric; v_ids bigint[]; v_sources text[];
BEGIN
  v_cfg := public.fx_active_config();
  SELECT max(rate), min(rate), count(*), array_agg(id), array_agg(DISTINCT source)
  INTO v_max, v_min, v_cnt, v_ids, v_sources
  FROM public.fx_rates_ledger
  WHERE pair = p_pair AND status = 'active' AND collected_at > now() - make_interval(hours => v_cfg.fx_stale_hours::int);

  IF v_cnt IS NULL OR v_cnt = 0 OR v_max IS NULL OR v_max <= 0 THEN
    RAISE EXCEPTION 'TAUX_INDISPONIBLE: aucune source validée fraîche pour %', p_pair;
  END IF;

  v_bill := round(v_max * (1 + v_cfg.fx_margin_percent / 100.0));   -- facturer HAUT + marge
  v_pay  := v_min;                                                  -- payer BAS

  RETURN jsonb_build_object(
    'pair', p_pair, 'direction', p_direction,
    'taux_facturation', v_bill, 'taux_paiement', v_pay,
    'montant_facture', round(p_amount * v_bill),          -- ce que paie le payeur (devise cotée)
    'cout_paiement',   round(p_amount * v_pay),           -- coût de sourcing au taux bas
    'spread_estime',   round(p_amount * v_bill) - round(p_amount * v_pay),
    'rate_ids', v_ids, 'sources_utilisees', v_sources,
    'margin_percent', v_cfg.fx_margin_percent, 'quoted_at', now()
  );
END $$;
REVOKE ALL ON FUNCTION public.fx_quote(text, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_quote(text, numeric, text) TO authenticated, service_role;

-- ── 6) fx_convert : applique un quote DANS une transaction, crédite le spread au PDG, trace ──
-- À appeler par les RPC financières (rewiring = chantier staging). Écrit le revenu de spread au
-- wallet PDG (fx_spread_revenue) et renvoie les montants + rate_ids pour traçage des legs appelants.
CREATE OR REPLACE FUNCTION public.fx_convert(p_pair text, p_amount numeric, p_direction text, p_ref text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_q jsonb; v_spread numeric; v_pdg bigint;
BEGIN
  v_q := public.fx_quote(p_pair, p_amount, p_direction);
  v_spread := (v_q->>'spread_estime')::numeric;
  IF v_spread > 0 THEN
    v_pdg := public.get_pdg_gnf_wallet_id();
    IF v_pdg IS NOT NULL THEN
      -- Le spread est en devise cotée (GNF pour */GNF) → crédité au coffre PDG GNF.
      UPDATE public.wallets SET balance = COALESCE(balance,0) + v_spread, updated_at = now() WHERE id = v_pdg;
      INSERT INTO public.agent_cash_audit_log (severity, event, detail)
      VALUES ('info', 'fx_spread_revenue', jsonb_build_object('pair', p_pair, 'amount', p_amount,
        'spread', v_spread, 'ref', p_ref, 'rate_ids', v_q->'rate_ids', 'quote', v_q));
    END IF;
  END IF;
  RETURN v_q || jsonb_build_object('spread_credited', v_spread, 'pdg_wallet', v_pdg);
END $$;
REVOKE ALL ON FUNCTION public.fx_convert(text, numeric, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_convert(text, numeric, text, text) TO service_role;

-- ── 7) Monitor 24/7 : domaine fx (format { checks: [...] }) ──
CREATE OR REPLACE FUNCTION public.fx_monitor_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_quarantine int; v_verification int; v_stale int; v_rejected_24h int;
BEGIN
  SELECT count(*) INTO v_quarantine FROM public.fx_rates_ledger WHERE status='quarantine' AND created_at < now() - interval '2 hours';
  SELECT count(*) INTO v_verification FROM public.fx_rates_ledger WHERE status='verification';
  SELECT count(*) INTO v_rejected_24h FROM public.fx_rates_ledger WHERE status='rejected' AND created_at > now() - interval '24 hours';
  -- Paires connues (bornes définies) sans aucun taux actif frais < 24h.
  SELECT count(*) INTO v_stale FROM public.fx_pair_bounds b
  WHERE NOT EXISTS (SELECT 1 FROM public.fx_rates_ledger l
    WHERE l.pair = b.pair AND l.status='active' AND l.collected_at > now() - interval '24 hours');

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','fx_quarantine_stuck','label','Taux en quarantaine > 2h non traités','severity','critical','count',v_quarantine,'observed',v_quarantine),
    jsonb_build_object('key','fx_verification_open','label','Taux en vérification (divergence)','severity','warning','count',v_verification,'observed',v_verification),
    jsonb_build_object('key','fx_pair_stale','label','Paires sans taux frais < 24h','severity','critical','count',v_stale,'observed',v_stale),
    jsonb_build_object('key','fx_rejected_24h','label','Taux rejetés (hors bornes) 24h','severity','warning','count',v_rejected_24h,'observed',v_rejected_24h)
  ));
END $$;
REVOKE ALL ON FUNCTION public.fx_monitor_report() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.fx_monitor_report() TO authenticated, service_role;

-- ── Sentinelles (l'event trigger DDL argent existant les couvre automatiquement) ──
COMMENT ON TABLE public.fx_rates_ledger IS 'FX ledger append-only — trigger d''immuabilité obligatoire. Source de vérité des taux validés. NE JAMAIS permettre UPDATE des colonnes de valeur.';
COMMENT ON FUNCTION public.fx_quote(text, numeric, text) IS 'Moteur directionnel : facturer HAUT (max+marge) / payer BAS (min). Garde TAUX_INDISPONIBLE. NE JAMAIS retourner un taux de source non validée.';
COMMENT ON FUNCTION public.fx_convert(text, numeric, text, text) IS 'Applique fx_quote en transaction + crédite le spread au wallet PDG (fx_spread_revenue). Money-critical.';

-- ── 8) TESTS (portes + exemple canonique PDG) — rollback à la fin, aucune donnée persistée ──
DO $$
DECLARE r jsonb; v_q jsonb; v_bill numeric; v_pay numeric;
BEGIN
  -- Isole les tests sur une paire dédiée pour ne pas polluer les vraies paires.
  INSERT INTO public.fx_pair_bounds (pair, min_rate, max_rate) VALUES ('TST/GNF', 7000, 12000) ON CONFLICT (pair) DO NOTHING;

  -- (a) hors bornes → rejected
  r := public.fx_ingest_rate('TST/GNF', 99999, 'bcrg', now());
  IF r->>'status' <> 'rejected' THEN RAISE EXCEPTION 'TEST portes: hors bornes non rejeté (got %)', r->>'status'; END IF;

  -- Exemple canonique PDG : 3 sources validées {8742, 8800, 8942}
  PERFORM public.fx_ingest_rate('TST/GNF', 8742, 'bcrg',    now());
  PERFORM public.fx_ingest_rate('TST/GNF', 8800, 'bceao',   now());
  PERFORM public.fx_ingest_rate('TST/GNF', 8942, 'ecobank', now());

  v_q := public.fx_quote('TST/GNF', 1, 'sell_base');
  v_bill := (v_q->>'taux_facturation')::numeric;
  v_pay  := (v_q->>'taux_paiement')::numeric;
  -- 8942 × 1,05 = 9389,1 → 9389 ; paiement = min = 8742 ; spread = 647.
  IF v_bill <> 9389 THEN RAISE EXCEPTION 'TEST canonique: facturation attendue 9389, got %', v_bill; END IF;
  IF v_pay <> 8742 THEN RAISE EXCEPTION 'TEST canonique: paiement attendu 8742, got %', v_pay; END IF;
  IF (v_q->>'spread_estime')::numeric <> 647 THEN RAISE EXCEPTION 'TEST canonique: spread attendu 647, got %', v_q->>'spread_estime'; END IF;

  -- (b) variation 6% vs actif ecobank (8942 → 9479 = +6%) → quarantine
  r := public.fx_ingest_rate('TST/GNF', round(8942 * 1.06), 'ecobank', now());
  IF r->>'status' <> 'quarantine' THEN RAISE EXCEPTION 'TEST portes: variation 6%% non quarantaine (got %)', r->>'status'; END IF;

  -- (c) divergence vs médiane (~8800) : 8800×1,04 = 9152 (~+4% > 3%) via nouvelle source → verification
  r := public.fx_ingest_rate('TST/GNF', round(8800 * 1.04), 'uba', now());
  IF r->>'status' <> 'verification' THEN RAISE EXCEPTION 'TEST portes: divergence non vérification (got %)', r->>'status'; END IF;

  RAISE NOTICE 'OK FX : portes (bornes/variation/divergence) + exemple canonique (9389 / 8742 / spread 647) validés.';
  -- Nettoyage des données de test (append-only : on retire via chemin privilégié DDL — ici DELETE
  -- direct autorisé au sein de la migration car le trigger bloque DELETE ; on désactive le trigger
  -- le temps du nettoyage de test uniquement).
  ALTER TABLE public.fx_rates_ledger DISABLE TRIGGER trg_fx_ledger_immutable;
  DELETE FROM public.fx_rates_ledger WHERE pair = 'TST/GNF';
  ALTER TABLE public.fx_rates_ledger ENABLE TRIGGER trg_fx_ledger_immutable;
  DELETE FROM public.fx_pair_bounds WHERE pair = 'TST/GNF';
END $$;

SELECT 'FX ledger append-only + portes (bornes/variation/divergence) + moteur directionnel fx_quote/fx_convert + domaine monitor fx + tests OK. Socle ADDITIF (RPC argent live NON câblées — rewiring = chantier staging).' AS status;
