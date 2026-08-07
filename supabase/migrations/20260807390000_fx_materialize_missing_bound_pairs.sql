-- ═══════════════════════════════════════════════════════════════════════════
-- FX — matérialiser les paires DÉCLARÉES (fx_pair_bounds) mais ABSENTES de la table.
-- Le correctif précédent (20260807340000) rafraîchissait les paires PÉRIMÉES ; restaient
-- 5 devises déclarées dans les bornes mais qui n'ont JAMAIS eu de taux : KES, ZAR, DZD,
-- ETB, EGP → aucune conversion possible vers ces pays. Leurs jambes USD sont fraîches (1 h).
-- Même discipline que le pivot existant : jamais de taux inventé, les deux jambes doivent
-- être fraîches, sinon on ne crée RIEN (fail-closed). Idempotent (ON CONFLICT DO UPDATE).
-- Planifié avec le refresh des périmées. Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.fx_materialize_bound_pairs()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_b record; v_from text; v_to text; v_leg1 numeric; v_leg2 numeric; v_rate numeric;
  v_n int := 0; v_pairs jsonb := '[]'::jsonb;
BEGIN
  FOR v_b IN SELECT pair FROM public.fx_pair_bounds LOOP
    v_from := upper(split_part(replace(v_b.pair, '-', '/'), '/', 1));
    v_to   := upper(split_part(replace(v_b.pair, '-', '/'), '/', 2));
    IF v_from = '' OR v_to = '' OR v_from = v_to THEN CONTINUE; END IF;

    -- Déjà couverte (direct ou inverse, < 24 h) → rien à faire.
    IF EXISTS (SELECT 1 FROM public.currency_exchange_rates r
               WHERE r.retrieved_at > now() - interval '24 hours'
                 AND ((upper(r.from_currency) = v_from AND upper(r.to_currency) = v_to)
                   OR (upper(r.from_currency) = v_to AND upper(r.to_currency) = v_from)))
    THEN CONTINUE; END IF;

    SELECT rate INTO v_leg1 FROM public.currency_exchange_rates
      WHERE upper(from_currency) = v_from AND upper(to_currency) = 'USD'
        AND retrieved_at > now() - interval '24 hours'
      ORDER BY retrieved_at DESC LIMIT 1;
    SELECT rate INTO v_leg2 FROM public.currency_exchange_rates
      WHERE upper(from_currency) = 'USD' AND upper(to_currency) = v_to
        AND retrieved_at > now() - interval '24 hours'
      ORDER BY retrieved_at DESC LIMIT 1;
    IF v_leg1 IS NULL OR v_leg2 IS NULL OR v_leg1 <= 0 OR v_leg2 <= 0 THEN CONTINUE; END IF;

    v_rate := v_leg1 * v_leg2;
    INSERT INTO public.currency_exchange_rates (from_currency, to_currency, rate, source, retrieved_at)
    VALUES (v_from, v_to, v_rate, 'cross_usd_auto', now())
    ON CONFLICT (from_currency, to_currency) DO UPDATE
      SET rate = EXCLUDED.rate, source = EXCLUDED.source, retrieved_at = EXCLUDED.retrieved_at;
    v_n := v_n + 1;
    v_pairs := v_pairs || jsonb_build_object('pair', v_from || '→' || v_to, 'rate', v_rate);
  END LOOP;
  RETURN jsonb_build_object('materialized', v_n, 'pairs', v_pairs);
END $$;
REVOKE ALL ON FUNCTION public.fx_materialize_bound_pairs() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fx_materialize_bound_pairs() TO service_role;

COMMIT;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('fx-materialize-bound-pairs')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'fx-materialize-bound-pairs');
    PERFORM cron.schedule('fx-materialize-bound-pairs', '12 * * * *',
      'SELECT public.fx_materialize_bound_pairs();');
  END IF;
END $$;
