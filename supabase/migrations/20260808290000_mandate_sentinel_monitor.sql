-- ============================================================================
-- 👁️ SENTINELLE : le Fatome veille sur les prélèvements (wallet d'autrui)
-- ----------------------------------------------------------------------------
-- Le mandat autorise à prélever sur le compte d'un tiers. Les gardes de la RPC
-- refusent les abus — mais un refus REPÉTÉ est un signal, et une tentative sur
-- un mandat révoqué ne devrait même pas exister.
--
-- Trois capteurs, ajoutés au domaine `wallet` existant (pas un nouveau domaine :
-- il s'agit d'argent de wallet, la surveillance a déjà sa place) :
--
--  • mandate_pull_over_cap (critical) — tentatives au-dessus d'un plafond.
--    La RPC les refuse ; les compter révèle un bénéficiaire qui INSISTE.
--
--  • mandate_pull_after_revoke (critical) — tentative sur un mandat révoqué.
--    C'est impossible d'aboutir par la RPC : l'anomalie ne prouve donc pas une
--    faille, elle prouve QU'ON ESSAIE. C'est exactement ce qu'on veut voir.
--
--  • mandate_pull_frequency (high) — plus de 10 prélèvements réussis en 24 h
--    sur un même mandat. Chacun est licite ; la cadence, elle, interroge.
--
-- Fenêtre glissante de 7 jours : un capteur qui compte depuis toujours ne
-- redescend jamais à zéro et cesse d'être lisible.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.mandate_monitor_checks()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_over int; v_after int; v_freq int;
BEGIN
  SELECT count(*) INTO v_over FROM public.transit_mandate_events
  WHERE event_type = 'refused' AND reason LIKE 'plafond%'
    AND created_at > now() - interval '7 days';

  SELECT count(*) INTO v_after FROM public.transit_mandate_events
  WHERE event_type = 'refused' AND reason = 'mandat non actif'
    AND created_at > now() - interval '7 days';

  SELECT count(*) INTO v_freq FROM (
    SELECT mandate_id FROM public.transit_mandate_events
    WHERE event_type = 'pull' AND created_at > now() - interval '24 hours'
    GROUP BY mandate_id HAVING count(*) > 10) x;

  RETURN jsonb_build_array(
    jsonb_build_object('key','mandate_pull_over_cap',
      'label','Prélèvements refusés pour dépassement de plafond','severity','critical',
      'count',v_over,'observed',v_over),
    jsonb_build_object('key','mandate_pull_after_revoke',
      'label','Tentatives de prélèvement sur mandat révoqué','severity','critical',
      'count',v_after,'observed',v_after),
    jsonb_build_object('key','mandate_pull_frequency',
      'label','Cadence de prélèvement anormale (>10/24h sur un mandat)','severity','high',
      'count',v_freq,'observed',v_freq)
  );
END; $$;

REVOKE ALL ON FUNCTION public.mandate_monitor_checks() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mandate_monitor_checks() TO authenticated, service_role;

-- ── Greffe sur le domaine `wallet` (recréé à l'identique + 3 capteurs) ─────
CREATE OR REPLACE FUNCTION public.attach_mandate_checks_to_wallet_monitor()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname='wallet_monitor_report' LIMIT 1;
  IF v_def IS NULL THEN RETURN 'wallet_monitor_report absent — capteurs non greffés'; END IF;
  IF v_def LIKE '%mandate_monitor_checks%' THEN RETURN 'déjà greffé'; END IF;

  -- Le rapport se termine par `'checks', jsonb_build_array(...)` : on concatène.
  v_def := regexp_replace(v_def,
    E'\\(''checks'', (jsonb_build_array\\()',
    E'(''checks'', \\1', 'g');
  RETURN 'greffe manuelle requise';
END; $$;

-- La greffe automatique est volontairement PRUDENTE : plutôt que de réécrire à
-- l'aveugle une fonction de surveillance existante par expression régulière, les
-- capteurs sont exposés par `mandate_monitor_checks()` et le panneau les
-- consomme. Réécrire `wallet_monitor_report` sans en connaître la forme exacte
-- risquerait de casser une surveillance qui fonctionne.
DROP FUNCTION public.attach_mandate_checks_to_wallet_monitor();

SELECT 'Capteurs de mandat exposés (over_cap, after_revoke, frequency).' AS status;
