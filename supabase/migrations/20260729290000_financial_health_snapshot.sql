-- ============================================================================
-- DASHBOARD « SANTÉ FINANCIÈRE » (surveillance C.4) — un écran = l'état de tout l'argent
-- ----------------------------------------------------------------------------
-- `financial_health_snapshot()` : instantané agrégé pour le PDG — dernier contrôle d'intégrité
-- (vert/rouge par invariant), en-attente par circuit (quarantaine, pending_fx, retraits),
-- volumes du jour (via v_money_movements), décisions du routeur (24 h). service_role only
-- (le backend l'expose au PDG authentifié).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.financial_health_snapshot()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_run text; v_integrity jsonb; v_pending jsonb; v_volumes jsonb; v_router jsonb; v_fx jsonb;
BEGIN
  -- Dernier passage du compteur de dérive.
  SELECT details->>'run' INTO v_run FROM public.ledger_integrity_checks
   ORDER BY checked_at DESC LIMIT 1;
  SELECT jsonb_build_object(
      'run', v_run,
      'checked_at', max(checked_at),
      'total', count(*),
      'bad', count(*) FILTER (WHERE NOT ok),
      'all_ok', bool_and(ok),
      'invariants', jsonb_agg(jsonb_build_object('name', check_name, 'ok', ok, 'actual', actual) ORDER BY check_name)
    ) INTO v_integrity
   FROM public.ledger_integrity_checks WHERE details->>'run' = v_run;

  -- En attente par circuit.
  SELECT jsonb_build_object(
    'quarantine_pending', (SELECT jsonb_build_object('count', count(*), 'total', COALESCE(sum(amount),0))
                             FROM public.wallet_quarantined_funds WHERE status='pending'),
    'pending_fx',         (SELECT jsonb_build_object('count', count(*), 'total', COALESCE(sum(amount),0))
                             FROM public.payment_transactions WHERE status='pending_fx'),
    'withdrawals_pending',(SELECT jsonb_build_object('count', count(*), 'total', COALESCE(sum(amount),0))
                             FROM public.withdrawals WHERE status IN ('pending','processing')),
    'payments_pending',   (SELECT jsonb_build_object('count', count(*))
                             FROM public.payment_transactions WHERE status IN ('pending','processing'))
  ) INTO v_pending;

  -- Volumes du jour par circuit (nombre + total, par devise agrégée en texte).
  SELECT COALESCE(jsonb_agg(jsonb_build_object('circuit', circuit, 'count', n, 'currencies', cur)), '[]'::jsonb)
    INTO v_volumes
   FROM (SELECT circuit, count(*) n, jsonb_object_agg(currency, tot) cur
           FROM (SELECT circuit, currency, count(*) c, sum(amount) tot
                   FROM public.v_money_movements
                  WHERE occurred_at >= date_trunc('day', now())
                  GROUP BY circuit, currency) a
          GROUP BY circuit) b;

  -- Décisions du routeur (24 h) par prestataire + zone.
  SELECT COALESCE(jsonb_agg(jsonb_build_object('provider', provider, 'zone', zone, 'count', n)), '[]'::jsonb)
    INTO v_router
   FROM (SELECT provider, zone, count(*) n FROM public.payment_router_log
          WHERE created_at >= now() - interval '24 hours' GROUP BY provider, zone) r;

  -- État FX (taux les plus vieux actifs — signal de fraîcheur).
  SELECT jsonb_build_object('oldest_active_rate_at', min(retrieved_at), 'active_rates', count(*))
    INTO v_fx FROM public.currency_exchange_rates WHERE is_active = true;

  RETURN jsonb_build_object(
    'generated_at', now(),
    'integrity', COALESCE(v_integrity, jsonb_build_object('all_ok', null, 'invariants', '[]'::jsonb)),
    'pending', v_pending,
    'volumes_today', v_volumes,
    'router_24h', v_router,
    'fx', v_fx
  );
END $function$;

REVOKE ALL ON FUNCTION public.financial_health_snapshot() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.financial_health_snapshot() TO service_role;
