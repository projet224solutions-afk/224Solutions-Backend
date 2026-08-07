-- ═══════════════════════════════════════════════════════════════════════════
-- FX — le contrôle de fraîcheur accepte aussi le sens INVERSE.
-- `_acash_fx` convertit indifféremment avec le taux direct OU son inverse (documenté :
-- « directe/inverse puis cross USD »). Compter A/B comme « périmée » alors que B/A est
-- frais fabrique une alerte pour une conversion qui FONCTIONNE (cas XAF/GNF et MAD/GNF,
-- réparés ce soir dans le sens GNF→XAF / GNF→MAD).
-- Après ce correctif, ce qui reste au compteur est un VRAI trou : une devise déclarée
-- dans les bornes mais qu'aucune source ne fournit dans aucun sens.
-- Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.fx_monitor_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_quarantine int; v_verification int; v_stale int; v_rejected_24h int;
BEGIN
  SELECT count(*) INTO v_quarantine FROM public.fx_rates_ledger
    WHERE status='quarantine' AND created_at < now() - interval '2 hours';
  SELECT count(*) INTO v_verification FROM public.fx_rates_ledger WHERE status='verification';
  SELECT count(*) INTO v_rejected_24h FROM public.fx_rates_ledger
    WHERE status='rejected' AND created_at > now() - interval '24 hours';

  -- Paire couverte = taux frais (< 24 h) dans le LEDGER, ou dans la table canonique,
  -- dans le sens DIRECT ou dans le sens INVERSE (le convertisseur utilise les deux).
  SELECT count(*) INTO v_stale
  FROM public.fx_pair_bounds b
  WHERE NOT EXISTS (
          SELECT 1 FROM public.fx_rates_ledger l
          WHERE l.pair = b.pair AND l.status = 'active'
            AND l.collected_at > now() - interval '24 hours')
    AND NOT EXISTS (
          SELECT 1 FROM public.currency_exchange_rates r
          WHERE r.retrieved_at > now() - interval '24 hours'
            AND (
              (upper(r.from_currency) = upper(split_part(replace(b.pair, '-', '/'), '/', 1))
               AND upper(r.to_currency) = upper(split_part(replace(b.pair, '-', '/'), '/', 2)))
              OR
              (upper(r.to_currency)   = upper(split_part(replace(b.pair, '-', '/'), '/', 1))
               AND upper(r.from_currency) = upper(split_part(replace(b.pair, '-', '/'), '/', 2)))
            ));

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','fx_quarantine_stuck','label','Taux en quarantaine > 2h non traités','severity','critical','count',v_quarantine,'observed',v_quarantine),
    jsonb_build_object('key','fx_verification_open','label','Taux en vérification (divergence)','severity','warning','count',v_verification,'observed',v_verification),
    jsonb_build_object('key','fx_pair_stale','label','Devises déclarées SANS aucun taux frais (aucun sens, aucune source)','severity','critical','count',v_stale,'observed',v_stale),
    jsonb_build_object('key','fx_rejected_24h','label','Taux rejetés (hors bornes) 24h','severity','warning','count',v_rejected_24h,'observed',v_rejected_24h)
  ));
END $$;
REVOKE ALL ON FUNCTION public.fx_monitor_report() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fx_monitor_report() TO authenticated, service_role;

COMMIT;
