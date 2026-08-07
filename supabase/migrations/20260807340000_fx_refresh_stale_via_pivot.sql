-- ═══════════════════════════════════════════════════════════════════════════
-- FX — les paires PÉRIMÉES mais CALCULABLES sont rafraîchies par le pivot USD.
--
-- CONSTAT (07/08/2026) : GNF→MAD et GNF→XAF n'étaient plus collectées depuis 51 jours.
-- Impact RÉEL, pas cosmétique : `_acash_fx(1000,'GNF','XAF')` échoue en TAUX_INDISPONIBLE
-- (il trouve un taux DIRECT périmé et s'arrête, sans tenter le pivot) — donc aucun paiement
-- ne peut être converti vers la zone CEMAC ni le Maroc.
-- Or les jambes du pivot sont FRAÎCHES (GNF→USD, USD→XAF, USD→MAD : 0 h).
--
-- CHOIX : ne PAS toucher à `_acash_fx` (convertisseur de TOUT l'argent : commissions,
-- affiliation, agent cash — modification à faire à froid). On COMPLÈTE le collecteur :
-- pour chaque paire périmée dont les deux jambes USD sont fraîches, on écrit le taux croisé,
-- source tracée `cross_usd_auto` (même mécanique que les croisés existants). Le taux reste
-- donc TOUJOURS issu de données officielles fraîches — aucun taux inventé, aucun relâchement
-- de la garde de fraîcheur. Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.fx_refresh_stale_via_pivot(p_max_age_hours int DEFAULT 24)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pair record; v_leg1 numeric; v_leg2 numeric; v_rate numeric;
  v_n int := 0; v_pairs jsonb := '[]'::jsonb;
BEGIN
  FOR v_pair IN
    SELECT f.from_currency, f.to_currency, f.retrieved_at
    FROM (SELECT DISTINCT ON (from_currency, to_currency)
                 from_currency, to_currency, retrieved_at
          FROM public.currency_exchange_rates
          ORDER BY from_currency, to_currency, retrieved_at DESC) f
    WHERE f.retrieved_at < now() - make_interval(hours => GREATEST(COALESCE(p_max_age_hours,24),1))
      AND f.from_currency <> 'USD' AND f.to_currency <> 'USD'
  LOOP
    -- Jambe 1 : from → USD (fraîche obligatoire)
    SELECT rate INTO v_leg1 FROM public.currency_exchange_rates
    WHERE from_currency = v_pair.from_currency AND to_currency = 'USD'
      AND retrieved_at > now() - interval '24 hours'
    ORDER BY retrieved_at DESC LIMIT 1;
    -- Jambe 2 : USD → to (fraîche obligatoire)
    SELECT rate INTO v_leg2 FROM public.currency_exchange_rates
    WHERE from_currency = 'USD' AND to_currency = v_pair.to_currency
      AND retrieved_at > now() - interval '24 hours'
    ORDER BY retrieved_at DESC LIMIT 1;

    IF v_leg1 IS NULL OR v_leg2 IS NULL OR v_leg1 <= 0 OR v_leg2 <= 0 THEN
      CONTINUE;   -- pivot indisponible → on ne fabrique RIEN (fail-closed conservé)
    END IF;

    v_rate := v_leg1 * v_leg2;
    -- La table garde UNE ligne par paire (contrainte uq_currency_exchange_rates_pair) :
    -- on met à jour en place ; l'historique des taux vit dans fx_rate_history.
    INSERT INTO public.currency_exchange_rates (from_currency, to_currency, rate, source, retrieved_at)
    VALUES (v_pair.from_currency, v_pair.to_currency, v_rate, 'cross_usd_auto', now())
    ON CONFLICT (from_currency, to_currency) DO UPDATE
      SET rate = EXCLUDED.rate, source = EXCLUDED.source, retrieved_at = EXCLUDED.retrieved_at;
    v_n := v_n + 1;
    v_pairs := v_pairs || jsonb_build_object(
      'pair', v_pair.from_currency || '→' || v_pair.to_currency,
      'rate', v_rate, 'was_stale_since', v_pair.retrieved_at);
  END LOOP;

  RETURN jsonb_build_object('refreshed', v_n, 'pairs', v_pairs);
END; $$;
REVOKE ALL ON FUNCTION public.fx_refresh_stale_via_pivot(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fx_refresh_stale_via_pivot(int) TO service_role;

COMMIT;

-- Planification : 10 min après la collecte horaire (elle passe en premier, on complète après).
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('fx-refresh-stale-pivot')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'fx-refresh-stale-pivot');
    PERFORM cron.schedule('fx-refresh-stale-pivot', '10 * * * *',
      'SELECT public.fx_refresh_stale_via_pivot(24);');
  END IF;
END $$;
