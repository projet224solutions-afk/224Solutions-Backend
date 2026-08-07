-- ═══════════════════════════════════════════════════════════════════════════
-- ZONES — le « Final » garde sa PRÉCISION (l'arrondi appartient à l'affichage).
-- Preuve du test de marge (ZAR/GNF, 10 % → 11 %) : panneau 590 → 595 et devis 1000 ZAR
-- 590 135 → 595 500 — les deux bougent bien ensemble, mais 595 × 1000 = 595 000 ≠ 595 500 :
-- l'écart venait de l'arrondi du TAUX UNITAIRE à 0 décimale côté serveur. Un taux n'est pas
-- un montant : on le garde à 4 décimales pour que « taux du panneau × montant » redonne
-- EXACTEMENT le devis. L'arrondi à la devise reste ce qu'il doit être : appliqué au montant
-- final, par le moteur de transfert. Migration NOUVELLE.
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
      -- TAUX (pas un montant) : 4 décimales → taux × montant = le devis, au franc près.
      'final_rate', CASE WHEN v_rate IS NULL THEN NULL
                         ELSE round(v_rate * (1 + v_margin), 4) END);
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public._zones_rates_core(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._zones_rates_core(text[]) TO service_role;

COMMIT;
