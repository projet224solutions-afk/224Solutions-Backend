-- ═══════════════════════════════════════════════════════════════════════════
-- CONTRAT DE RÉSOLUTION DES ANOMALIES + le Général cesse de se juger lui-même.
--
-- ── §5 : RECENSEMENT (fait, données réelles du 08/08) ─────────────────────
-- Constat du prompt : « les 8 alertes de l'onglet Sentinelle portent des types NUS
-- (untraced_increase, released_no_ledger, …) levés par les migrations de diagnostic ».
-- VÉRIFICATION EN BASE : c'est INEXACT et il ne faut donc PAS créer de resolvers pour
-- des types qui n'existent pas. Les 7 anomalies actives portent TOUTES un type préfixé
-- et viennent de l'étage B :
--     aml:quarantine_pending · aml:wallet_over_cap · aml:untraced_increase ·
--     escrow:released_no_ledger · pos:pos_items_without_stock_movement ·
--     commission:commission_revenue_gap · dispute:disputes_open_overdue
--     (toutes : ref = 'monitor:<domaine>:<clé>:<jour>', detail.source = surveillance24x7_etageB)
-- L'onglet n'affiche que la partie DROITE du type (le domaine est rendu en badge à gauche
-- par splitType()) : d'où l'impression de « types nus ». Elles restent actives parce que
-- leur condition est ENCORE VRAIE (60 quarantaines, 3 wallets au plafond, 17 crédits non
-- tracés, 2 escrows sans ledger, 77 ventes POS sans stock, 2 commissions, 1 litige) —
-- c'est le comportement voulu : l'étage B les résout dès que le compteur retombe à 0.
--
-- TABLEAU COMPLET type → émetteur → resolver :
--   <domaine>:<clé> (15 domaines)          → étage B          → étage B si count=0        ✅
--   sentinel:sentinel_dead|_failing        → tick pg_cron     → même tick                 ✅
--   sentinel:sentinel_trigger_blind        → tick pg_cron     → même tick                 ✅
--   sentinel:general_dead                  → tick pg_cron     → même tick                 ✅
--   general:<clé>_dead|_suspect            → Fatome Général   → Général                   ✅
--   general:<clé>_heartbeat_missing        → Fatome Général   → Général                   ✅ (07/08)
--   feature:<clé> / feature_unregistered   → sondes           → fatome_incident_resolve   ✅
--   étage A (5 types ponctuels)            → triggers argent  → fatome_autoresolve_stage_a ✅ (07/08)
--   commission_revenue_gap (SANS préfixe)  → legacy pré-étage B → aucun                    ⚠️ traité ci-dessous
--   sentinel:sms_channel_test              → test manuel      → résolu manuellement        ✅
--
-- ── §6 : le Général ne peut pas se juger lui-même ─────────────────────────
-- Sa ligne affichait « INCONNU / — » avec un heartbeat de 32 s : il s'exclut (à raison) de
-- sa propre boucle de supervision, donc il n'a jamais de verdict. La vraie chaîne, c'est le
-- pg_cron qui le vérifie. On expose donc l'état du DERNIER TICK dans le statut de section,
-- pour que l'interface affiche « jugé par pg_cron » au lieu d'un faux « inconnu ».
-- Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1) Nettoyage des anomalies LEGACY sans préfixe (émetteur disparu) ──────
-- Types nus antérieurs à l'étage B : plus aucun émetteur ne peut les rafraîchir NI les
-- résoudre. Elles sont marquées résolues avec un motif explicite. Les anomalies dont la
-- condition est encore vraie sont RE-LEVÉES au prochain cycle sous leur type préfixé —
-- rien n'est masqué.
UPDATE public.fatome_anomalies
SET resolved = true,
    resolved_at = COALESCE(resolved_at, now()),
    resolution_source = 'legacy_type_no_emitter',
    detail = COALESCE(detail, '{}'::jsonb) || jsonb_build_object(
      'cleanup_note', 'Type sans préfixe de domaine : émetteur pré-étage B disparu. Si la condition est encore vraie, l''étage B la relève sous <domaine>:<clé>.')
WHERE resolved = false
  AND anomaly_type NOT LIKE '%:%';

-- ── 2) LA RÈGLE PERMANENTE, écrite là où on lève une anomalie ─────────────
COMMENT ON FUNCTION public.fatome_raise(text, text, text, jsonb) IS
'Lève une anomalie Fatome (idempotent par (anomaly_type, ref) — utiliser une réf DATÉE pour un check récurrent).

⚠️ RÈGLE PERMANENTE — CONTRAT DE RÉSOLUTION : tout nouveau type d''anomalie DOIT déclarer
son chemin de résolution, au choix :
  (a) un check RÉCURRENT qui appelle fatome_resolve_type(<type>) dès que sa condition
      retombe à zéro (modèle : étage B de surveillance24x7, tick fatome_deadman_tick) ;
  (b) un traitement manuel PDG explicite (fatome_anomaly_ack) documenté dans le libellé ;
  (c) pour un fait PONCTUEL non répétable (triggers de l''étage A), un balayage
      d''expiration (modèle : fatome_autoresolve_stage_a).
UNE ANOMALIE SANS RESOLVER EST UN BUG : elle reste active à vie, gonfle le compteur du PDG
et finit par lui apprendre à ignorer ses alertes.';

-- ── 3) §6 — le statut de section expose « qui juge le Général » ────────────
CREATE OR REPLACE FUNCTION public.fatome_section_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_hb record; v_reg jsonb; v_esc jsonb; v_tick record;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO v_hb FROM public.fatome_sentinel_heartbeat WHERE id = 1;

  -- Dernier passage du vérificateur EXTERNE (pg_cron) : c'est LUI qui juge le Général.
  SELECT run_at, ok, message INTO v_tick
  FROM public.fatome_activity_log WHERE fatome_key = 'fatome_deadman'
  ORDER BY run_at DESC LIMIT 1;

  SELECT jsonb_agg(jsonb_build_object(
      'fatome_key', r.fatome_key, 'label', r.label, 'criticality', r.criticality,
      'enabled', r.enabled, 'expected_interval_sec', r.expected_interval_sec,
      'last_beat', COALESCE(h.last_beat, CASE WHEN r.fatome_key='fatome_sentinelle' THEN v_hb.last_beat END),
      'age_seconds', round(extract(epoch from (now() - COALESCE(h.last_beat,
          CASE WHEN r.fatome_key='fatome_sentinelle' THEN v_hb.last_beat END))))::int,
      'last_ok', COALESCE(h.last_ok, CASE WHEN r.fatome_key='fatome_sentinelle' THEN v_hb.last_ok END),
      'last_error', COALESCE(h.last_error, CASE WHEN r.fatome_key='fatome_sentinelle' THEN v_hb.last_error END),
      'cycle_count', COALESCE(h.cycle_count, CASE WHEN r.fatome_key='fatome_sentinelle' THEN v_hb.cycle_count END),
      -- Le Général ne s'auto-évalue pas (auto-référence) : il est jugé par le pg_cron.
      'judged_by_cron', (r.fatome_key = 'fatome_general'),
      'last_verdict', CASE
        WHEN r.fatome_key = 'fatome_general' THEN
          CASE WHEN v_tick.run_at IS NULL THEN NULL
               ELSE jsonb_build_object(
                 'verdict', CASE WHEN v_tick.run_at > now() - interval '20 minutes' AND COALESCE(v_tick.ok, false)
                                 THEN 'SAIN' ELSE 'INCONNU' END,
                 'reason', 'jugé par pg_cron — dernier tick ' ||
                           to_char(v_tick.run_at AT TIME ZONE 'UTC', 'HH24:MI:SS') || ' UTC' ||
                           CASE WHEN COALESCE(v_tick.ok, false) THEN ' (OK)' ELSE ' (en erreur)' END,
                 'run_at', v_tick.run_at) END
        ELSE (SELECT jsonb_build_object('verdict', c.verdict, 'reason', c.reason, 'run_at', c.run_at)
              FROM public.fatome_general_checks c
              WHERE c.fatome_key = r.fatome_key ORDER BY c.run_at DESC LIMIT 1) END
    ) ORDER BY r.fatome_key)
  INTO v_reg
  FROM public.fatome_registry r
  LEFT JOIN public.fatome_heartbeats h ON h.fatome_key = r.fatome_key;

  v_esc := public.fatome_escalation_level();
  RETURN jsonb_build_object(
    'sentinel', jsonb_build_object(
      'has_heartbeat', v_hb.id IS NOT NULL, 'last_beat', v_hb.last_beat,
      'age_seconds', round(extract(epoch from (now() - v_hb.last_beat)))::int,
      'last_ok', v_hb.last_ok, 'last_error', v_hb.last_error, 'cycle_count', v_hb.cycle_count),
    'registry', COALESCE(v_reg, '[]'::jsonb),
    'escalation', v_esc,
    'cron_tick', CASE WHEN v_tick.run_at IS NULL THEN NULL
                      ELSE jsonb_build_object('run_at', v_tick.run_at, 'ok', v_tick.ok,
                        'age_seconds', round(extract(epoch from (now() - v_tick.run_at)))::int) END,
    'generated_at', now());
END; $$;
REVOKE ALL ON FUNCTION public.fatome_section_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_section_status() TO authenticated, service_role;

COMMIT;
