-- ═══════════════════════════════════════════════════════════════════════════
-- 👻 FATOME EXCHANGE V2 — VAGUE 1 (améliore SANS casser, ZÉRO IA)
-- C0 : unification de la marge (fx_pair_config = SOURCE UNIQUE) + resolver canonique.
-- C1 : sources OFFICIELLES (banques centrales) + stratégies de lecture scorées.
-- C2 : historique des taux + détection d'anomalie statistique (moyenne 7 j ± seuil PDG).
-- Additif et non-régressif : aucune fonction existante supprimée, valeurs par défaut
-- calquées sur l'existant (le resolver global rend EXACTEMENT margin_config aujourd'hui).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── C0.1 — La faille margin_config : DÉJÀ fermée (policies PDG-only en prod).
-- On DURCIT explicitement par idempotence (au cas où un env aurait encore l'ancienne
-- policy permissive USING(true)) : on retire toute policy d'écriture permissive et on
-- garantit PDG/service_role seul en écriture, SELECT public conservé (taux publics).
DO $$
BEGIN
  -- Retirer d'éventuelles policies permissives héritées (no-op si absentes).
  DROP POLICY IF EXISTS "Authenticated can update margin_config" ON public.margin_config;
  DROP POLICY IF EXISTS "Authenticated can insert margin_config" ON public.margin_config;
  DROP POLICY IF EXISTS margin_config_write_all ON public.margin_config;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

-- ── C0.2 — fx_pair_config devient la SOURCE UNIQUE de la marge par paire.
-- Ligne globale '*' = défaut, SEEDÉE depuis margin_config.default_margin (fraction→%).
INSERT INTO public.fx_pair_config (pair, currency_class, margin_percent, operations_enabled)
SELECT '*', 'flottante_volatile',
       round(coalesce((SELECT config_value FROM public.margin_config WHERE config_key = 'default_margin'), 0.05) * 100, 4),
       true
WHERE NOT EXISTS (SELECT 1 FROM public.fx_pair_config WHERE pair = '*');

-- RESOLVER CANONIQUE (une seule vérité) → renvoie une FRACTION (0.05 = 5 %).
-- Priorité : marge de la paire exacte → marge globale '*' → margin_config → 3 %.
-- Accepte 'USD/GNF' ou 'USD','GNF'. Non-régressif : sans override de paire, rend le défaut global
-- = margin_config aujourd'hui, donc identique au comportement LIVE actuel.
CREATE OR REPLACE FUNCTION public.fx_effective_margin_fraction(p_pair text)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(
    (SELECT margin_percent / 100.0 FROM public.fx_pair_config
      WHERE pair = upper(p_pair) AND margin_percent IS NOT NULL),
    (SELECT margin_percent / 100.0 FROM public.fx_pair_config
      WHERE pair = '*' AND margin_percent IS NOT NULL),
    (SELECT config_value FROM public.margin_config WHERE config_key = 'default_margin'),
    0.03
  );
$$;
REVOKE ALL ON FUNCTION public.fx_effective_margin_fraction(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fx_effective_margin_fraction(text) TO authenticated, service_role;
COMMENT ON TABLE public.margin_config IS
  'DÉPRÉCIÉ (Fatome V2) : la marge par paire vit dans fx_pair_config (resolver fx_effective_margin_fraction). margin_config = seed du défaut global ''*'' + compat lecture. Ne plus écrire ici.';

-- ── C2 — Historique des taux (la mémoire du Fatome) ─────────────────────────
CREATE TABLE IF NOT EXISTS public.fx_rate_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  from_currency text NOT NULL,
  to_currency text NOT NULL,
  rate numeric NOT NULL CHECK (rate > 0),
  source text,
  collected_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_fx_hist_pair_time
  ON public.fx_rate_history (from_currency, to_currency, collected_at DESC);
ALTER TABLE public.fx_rate_history ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fxh_read_all ON public.fx_rate_history;
CREATE POLICY fxh_read_all ON public.fx_rate_history FOR SELECT TO authenticated USING (true);
-- Écriture réservée aux fonctions SECURITY DEFINER (aucune policy INSERT).

-- Seuil d'anomalie PDG (défaut ±10 %) — colonne additive sur fx_config (singleton).
ALTER TABLE public.fx_config ADD COLUMN IF NOT EXISTS fx_anomaly_threshold_percent numeric NOT NULL DEFAULT 10
  CHECK (fx_anomaly_threshold_percent > 0 AND fx_anomaly_threshold_percent <= 100);

-- Enregistre un taux à l'historique ET dit s'il est ANORMAL (écart > seuil vs moyenne 7 j).
-- Pur code déterministe : moyenne mobile 7 j de la paire ; < 3 points d'historique = pas d'avis
-- (on ne rejette pas faute de mémoire — le premier taux entre, la mémoire se construit).
-- Retour : jsonb { anomaly bool, deviation numeric, avg7 numeric, samples int }.
CREATE OR REPLACE FUNCTION public.fx_record_and_check(
  p_from text, p_to text, p_rate numeric, p_source text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_avg numeric; v_n int; v_dev numeric; v_thr numeric; v_anom boolean := false;
BEGIN
  SELECT avg(rate), count(*) INTO v_avg, v_n FROM public.fx_rate_history
  WHERE from_currency = upper(p_from) AND to_currency = upper(p_to)
    AND collected_at >= now() - interval '7 days';
  SELECT fx_anomaly_threshold_percent / 100.0 INTO v_thr FROM public.fx_active_config();

  IF v_n >= 3 AND v_avg > 0 THEN
    v_dev := abs(p_rate - v_avg) / v_avg;
    IF v_dev > coalesce(v_thr, 0.10) THEN v_anom := true; END IF;
  END IF;

  -- On enregistre TOUJOURS le taux observé (mémoire), même anormal — la décision de
  -- l'utiliser appartient à l'appelant (rejet côté collecte si anomaly=true).
  INSERT INTO public.fx_rate_history (from_currency, to_currency, rate, source)
  VALUES (upper(p_from), upper(p_to), p_rate, p_source);

  RETURN jsonb_build_object('anomaly', v_anom, 'deviation', coalesce(v_dev, 0),
    'avg7', coalesce(v_avg, 0), 'samples', coalesce(v_n, 0));
END;
$$;
REVOKE ALL ON FUNCTION public.fx_record_and_check(text, text, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fx_record_and_check(text, text, numeric, text) TO service_role;

-- ── C1 — Sources OFFICIELLES (banques centrales) + stratégies de lecture scorées ─
CREATE TABLE IF NOT EXISTS public.fx_official_sources (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  country_code text NOT NULL,
  currency text NOT NULL,
  central_bank text NOT NULL,
  official_url text NOT NULL,
  is_active boolean NOT NULL DEFAULT false,   -- activée dès qu'un inscrit du pays existe
  surveillance_tier text NOT NULL DEFAULT 'low' CHECK (surveillance_tier IN ('realtime', 'low')),
  last_success_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (currency)
);
ALTER TABLE public.fx_official_sources ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fxos_read ON public.fx_official_sources;
CREATE POLICY fxos_read ON public.fx_official_sources FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS fxos_pdg_write ON public.fx_official_sources;
CREATE POLICY fxos_pdg_write ON public.fx_official_sources FOR ALL TO authenticated
  USING (is_admin_or_pdg()) WITH CHECK (is_admin_or_pdg());

-- Plusieurs chemins de lecture DU MÊME site officiel (auto-réparation sans IA) : chaque
-- stratégie a un score succès/échec ; la mieux notée passe en tête. Un site change de
-- présentation → une autre stratégie prend le relais.
CREATE TABLE IF NOT EXISTS public.fx_source_strategies (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  currency text NOT NULL,
  strategy_key text NOT NULL,
  method text NOT NULL CHECK (method IN ('css', 'regex', 'json')),
  extractor text NOT NULL,           -- sélecteur CSS / motif regex / chemin JSON
  success_count int NOT NULL DEFAULT 0,
  fail_count int NOT NULL DEFAULT 0,
  last_ok_at timestamptz,
  enabled boolean NOT NULL DEFAULT true,
  UNIQUE (currency, strategy_key)
);
ALTER TABLE public.fx_source_strategies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fxss_read ON public.fx_source_strategies;
CREATE POLICY fxss_read ON public.fx_source_strategies FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS fxss_pdg_write ON public.fx_source_strategies;
CREATE POLICY fxss_pdg_write ON public.fx_source_strategies FOR ALL TO authenticated
  USING (is_admin_or_pdg()) WITH CHECK (is_admin_or_pdg());

-- Score de fiabilité (succès / total) — l'ordre de tentative des stratégies.
CREATE OR REPLACE FUNCTION public.fx_strategy_score(p_success int, p_fail int)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_success + p_fail = 0 THEN 0.5
              ELSE p_success::numeric / (p_success + p_fail) END;
$$;

-- Met à jour le score d'une stratégie après une tentative (appelé par le collecteur).
CREATE OR REPLACE FUNCTION public.fx_strategy_record(p_currency text, p_key text, p_ok boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.fx_source_strategies
  SET success_count = success_count + CASE WHEN p_ok THEN 1 ELSE 0 END,
      fail_count    = fail_count    + CASE WHEN p_ok THEN 0 ELSE 1 END,
      last_ok_at    = CASE WHEN p_ok THEN now() ELSE last_ok_at END
  WHERE currency = upper(p_currency) AND strategy_key = p_key;
END;
$$;
REVOKE ALL ON FUNCTION public.fx_strategy_record(text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fx_strategy_record(text, text, boolean) TO service_role;

-- Active la surveillance temps réel de la banque centrale d'un pays dès qu'un inscrit
-- de ce pays existe (appelée au signup — voir hook backend).
CREATE OR REPLACE FUNCTION public.fx_activate_country_source(p_currency text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.fx_official_sources
  SET is_active = true, surveillance_tier = 'realtime', updated_at = now()
  WHERE currency = upper(p_currency);
END;
$$;
REVOKE ALL ON FUNCTION public.fx_activate_country_source(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fx_activate_country_source(text) TO authenticated, service_role;

-- Seed des banques centrales officielles des pays de la plateforme (URLs officielles).
INSERT INTO public.fx_official_sources (country_code, currency, central_bank, official_url, surveillance_tier) VALUES
  ('GN', 'GNF', 'Banque Centrale de la République de Guinée (BCRG)', 'https://www.bcrg-guinee.org', 'realtime'),
  ('SL', 'SLE', 'Bank of Sierra Leone (BSL)', 'https://www.bsl.gov.sl', 'low'),
  ('SN', 'XOF', 'BCEAO (UEMOA)', 'https://www.bceao.int/fr/cours/cours-des-devises', 'realtime'),
  ('NG', 'NGN', 'Central Bank of Nigeria (CBN)', 'https://www.cbn.gov.ng/rates/', 'low'),
  ('GH', 'GHS', 'Bank of Ghana (BoG)', 'https://www.bog.gov.gh/economic-data/exchange-rate/', 'low'),
  ('LR', 'LRD', 'Central Bank of Liberia (CBL)', 'https://www.cbl.org.lr', 'low'),
  ('GM', 'GMD', 'Central Bank of The Gambia (CBG)', 'https://www.cbg.gm', 'low'),
  ('CM', 'XAF', 'BEAC (CEMAC)', 'https://www.beac.int', 'low')
ON CONFLICT (currency) DO NOTHING;

-- Activer les sources des devises DÉJÀ présentes (pays avec ≥1 utilisateur historique).
UPDATE public.fx_official_sources s SET is_active = true
WHERE EXISTS (
  SELECT 1 FROM public.currency_exchange_rates r
  WHERE r.is_active AND (r.from_currency = s.currency OR r.to_currency = s.currency)
);

-- ── C1 (suite) — Stratégies de lecture SCORÉES des banques réellement lisibles ─
-- BCRG (Guinée) et BCEAO (zone XOF) : plusieurs chemins d'extraction du MÊME site officiel.
-- Le collecteur essaie par score décroissant ; un échec baisse le score, un autre chemin prend
-- le relais. (Les banques non scrapables restent en 'low' — repli de fraîcheur, cf. règle d'or.)
INSERT INTO public.fx_source_strategies (currency, strategy_key, method, extractor) VALUES
  ('GNF', 'bcrg_fixing_table', 'css', 'table.cours-devises tr td:nth-child(2)'),
  ('GNF', 'bcrg_homepage_regex', 'regex', 'USD[^0-9]{0,20}([0-9][0-9\s.,]{3,})'),
  ('GNF', 'bcrg_json_api', 'json', '$.rates.USD'),
  ('XOF', 'bceao_cours_table', 'css', 'table.cours tr td.devise-usd'),
  ('XOF', 'bceao_regex', 'regex', 'Dollar[^0-9]{0,20}([0-9][0-9\s.,]{3,})')
ON CONFLICT (currency, strategy_key) DO NOTHING;

-- ── C1 (suite) — Surveillance AUTO au nouvel inscrit : un profil d'un pays active la
-- source officielle de ce pays en temps réel (trigger additif, best-effort, jamais bloquant).
CREATE OR REPLACE FUNCTION public.fx_profile_activate_source()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.country_code IS NOT NULL THEN
    UPDATE public.fx_official_sources
    SET is_active = true, surveillance_tier = 'realtime', updated_at = now()
    WHERE upper(country_code) = upper(NEW.country_code) AND NOT (is_active AND surveillance_tier = 'realtime');
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW; -- jamais bloquer une inscription pour une activation de surveillance
END;
$$;
DROP TRIGGER IF EXISTS trg_fx_activate_source ON public.profiles;
CREATE TRIGGER trg_fx_activate_source
  AFTER INSERT OR UPDATE OF country_code ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.fx_profile_activate_source();
