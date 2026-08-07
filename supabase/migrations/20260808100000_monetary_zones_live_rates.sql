-- ═══════════════════════════════════════════════════════════════════════════
-- ZONES MONÉTAIRES — le panneau PDG rebranché sur la source VIVANTE.
--
-- CONSTAT : « aucun taux · périmé » sur TOUTES les devises alors que Fatome X collecte
-- 294 paires fraîches. `PDGMonetaryZones` lit `fx_rates_ledger` — table du design de
-- juillet que PLUS RIEN n'alimente (**0 ligne en base**, vérifié) ; la refonte Fatome v2
-- écrit dans `currency_exchange_rates`.
--
-- CE QUE FAIT CETTE RPC : une seule lecture PDG qui renvoie, par paire, EXACTEMENT ce
-- qu'un client paierait — le mid réel + la marge résolue par le MÊME résolveur que les
-- transferts (`fx_effective_margin_fraction`, source unique `fx_pair_config`). Le panneau
-- ne recalcule plus rien : impossible qu'il diverge du prix réellement facturé.
-- Le sens INVERSE est couvert (le collecteur stocke tantôt A→B, tantôt B→A) et la
-- fraîcheur est jugée sur `freshness_hours` DE LA PAIRE, jamais sur une constante.
-- ⚠️ Le circuit des MARGES n'est pas touché : on le LIT, on ne le double pas.
-- Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.pdg_monetary_zones_rates(p_pairs text[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pair text; v_from text; v_to text;
  v_rate numeric; v_src text; v_at timestamptz; v_dir text;
  v_margin numeric; v_fresh_h numeric; v_out jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;

  FOREACH v_pair IN ARRAY COALESCE(p_pairs, ARRAY[]::text[]) LOOP
    v_from := upper(split_part(replace(v_pair, '-', '/'), '/', 1));
    v_to   := upper(split_part(replace(v_pair, '-', '/'), '/', 2));
    v_rate := NULL; v_src := NULL; v_at := NULL; v_dir := NULL;

    -- Sens DIRECT (le plus récent).
    SELECT r.rate, r.source, r.retrieved_at INTO v_rate, v_src, v_at
    FROM public.currency_exchange_rates r
    WHERE upper(r.from_currency) = v_from AND upper(r.to_currency) = v_to
    ORDER BY r.retrieved_at DESC LIMIT 1;
    IF v_rate IS NOT NULL THEN v_dir := 'direct'; END IF;

    -- Sinon le sens INVERSE, converti (le collecteur stocke parfois B→A).
    IF v_rate IS NULL THEN
      SELECT 1 / NULLIF(r.rate, 0), r.source, r.retrieved_at INTO v_rate, v_src, v_at
      FROM public.currency_exchange_rates r
      WHERE upper(r.from_currency) = v_to AND upper(r.to_currency) = v_from
        AND r.rate <> 0
      ORDER BY r.retrieved_at DESC LIMIT 1;
      IF v_rate IS NOT NULL THEN v_dir := 'inverse'; END IF;
    END IF;

    -- Marge EFFECTIVE : le résolveur des transferts, pas une copie.
    v_margin := public.fx_effective_margin_fraction(v_pair);
    SELECT freshness_hours INTO v_fresh_h FROM public.fx_pair_config WHERE pair = v_pair;
    v_fresh_h := COALESCE(v_fresh_h, 24);

    v_out := v_out || jsonb_build_object(
      'pair', v_pair,
      'rate', v_rate,                       -- MID brut
      'source', v_src,
      'direction', v_dir,                   -- direct | inverse | null
      'collected_at', v_at,
      'age_hours', CASE WHEN v_at IS NULL THEN NULL
                        ELSE round(extract(epoch from (now() - v_at)) / 3600.0, 2) END,
      'freshness_hours', v_fresh_h,
      'fresh', (v_at IS NOT NULL AND v_at > now() - make_interval(hours => v_fresh_h::int)),
      'margin_fraction', v_margin,
      'margin_percent', round(v_margin * 100, 2),
      -- Ce que le client paie réellement : mid × (1 + marge), arrondi à la devise cible.
      'final_rate', CASE WHEN v_rate IS NULL THEN NULL
                         ELSE round(v_rate * (1 + v_margin), public._ccy_decimals(v_to)) END);
  END LOOP;

  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.pdg_monetary_zones_rates(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pdg_monetary_zones_rates(text[]) TO authenticated, service_role;

-- ── DÉPRÉCIATION de fx_rates_ledger (pas de table zombie, pas de DROP) ──────
COMMENT ON TABLE public.fx_rates_ledger IS
'DEPRECATED 07/08/2026 — remplacée par currency_exchange_rates (refonte Fatome v2, migration 20260806170000).
Aucune écriture depuis le 06/08/2026 (table VIDE : 0 ligne au moment de la dépréciation).
Conservée en LECTURE HISTORIQUE uniquement. Ne PAS y écrire, ne PAS y lire pour de l''affichage
ou du calcul de prix : la source vivante est currency_exchange_rates, et le prix client se lit
via pdg_monetary_zones_rates() / fx_effective_margin_fraction().
Décision explicite : on ne maintient pas deux vérités (la double écriture a été refusée).';

-- Écritures révoquées : plus personne ne peut ré-alimenter une source morte par erreur.
REVOKE INSERT, UPDATE, DELETE ON public.fx_rates_ledger FROM PUBLIC, anon, authenticated;

COMMIT;
