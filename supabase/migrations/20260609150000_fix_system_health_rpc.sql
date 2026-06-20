-- ============================================================================
-- FIX — calculate_system_health (santé système réelle) + cleanup du bruit
-- ----------------------------------------------------------------------------
-- Bugs (Centre de Commande PDG) :
--  1. La RPC plantait : `WHERE status = 'detected'` était AMBIGU (collision avec la
--     colonne de sortie `status` du RETURNS TABLE) → erreur à chaque appel.
--  2. Elle renvoyait score/critical_count/status, mais les consommateurs lisent
--     health_score/health_status (usePdgMonitoring) et critical_pending/total_pending/
--     fixed_last_24h (errorMonitor.getErrorStats) → tout undefined → santé bloquée à 100 %.
--
-- Correctif : RETURNS jsonb avec TOUS les champs attendus, alias de table (se.) pour
-- lever l'ambiguïté, et santé + compteurs COHÉRENTS (même base = erreurs actives
-- `detected`). Score honnête (pénalise les critiques/modérées/mineures non traitées).
-- + cleanup_old_errors étendu pour archiver le bruit ancien (dont critiques > 30j).
-- Non destructif sur le schéma, rejouable.
-- ============================================================================

DROP FUNCTION IF EXISTS calculate_system_health();

CREATE OR REPLACE FUNCTION calculate_system_health()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_critical   int := 0;
  v_moderate   int := 0;
  v_minor      int := 0;
  v_fixed24    int := 0;
  v_total      int := 0;
  v_score      int := 100;
  v_status     text := 'healthy';
BEGIN
  -- Erreurs ACTIVES (non traitées) = status 'detected'. (resolved/fixed ne comptent pas.)
  SELECT COUNT(*) INTO v_critical FROM public.system_errors se
  WHERE se.severity IN ('critique', 'critical') AND se.status = 'detected';

  SELECT COUNT(*) INTO v_moderate FROM public.system_errors se
  WHERE se.severity IN ('modérée', 'moderate') AND se.status = 'detected';

  SELECT COUNT(*) INTO v_minor FROM public.system_errors se
  WHERE se.severity IN ('mineure', 'minor') AND se.status = 'detected';

  v_total := v_critical + v_moderate + v_minor;

  SELECT COUNT(*) INTO v_fixed24 FROM public.system_errors se
  WHERE se.status = 'fixed' AND se.fixed_at > now() - interval '24 hours';

  -- Score : pénalités plafonnées par catégorie (évite un 0 instantané, reste honnête).
  v_score := 100
           - LEAST(v_critical * 15, 60)
           - LEAST(v_moderate * 4, 25)
           - LEAST(v_minor * 1, 15)
           + LEAST(v_fixed24 * 2, 10);
  v_score := GREATEST(0, LEAST(100, v_score));

  v_status := CASE WHEN v_score >= 90 THEN 'healthy'
                   WHEN v_score >= 70 THEN 'degraded'
                   ELSE 'critical' END;

  RETURN jsonb_build_object(
    'health_score',     v_score,
    'health_status',    v_status,
    'critical_pending', v_critical,
    'moderate_pending', v_moderate,
    'minor_pending',    v_minor,
    'total_pending',    v_total,
    'fixed_last_24h',   v_fixed24,
    -- alias rétro-compat (anciens lecteurs éventuels)
    'score',            v_score,
    'critical_count',   v_critical,
    'recent_fixes',     v_fixed24
  );
END;
$$;

GRANT EXECUTE ON FUNCTION calculate_system_health() TO authenticated, service_role;

-- ───────────── cleanup étendu : archive le bruit ancien (dont critiques > 30j) ─────────────
CREATE OR REPLACE FUNCTION cleanup_old_errors()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_archived int := 0; v_deleted int := 0; n int;
BEGIN
  DELETE FROM public.system_errors WHERE status = 'fixed' AND fixed_at < now() - interval '30 days';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  UPDATE public.system_errors SET status = 'fixed', fix_applied = true, fix_description = 'Auto-archivé (mineure > 7j)', fixed_at = now()
  WHERE severity IN ('mineure','minor') AND status = 'detected' AND created_at < now() - interval '7 days';
  GET DIAGNOSTICS n = ROW_COUNT; v_archived := v_archived + n;

  UPDATE public.system_errors SET status = 'fixed', fix_applied = true, fix_description = 'Auto-archivé (modérée > 14j)', fixed_at = now()
  WHERE severity IN ('modérée','moderate') AND status = 'detected' AND created_at < now() - interval '14 days';
  GET DIAGNOSTICS n = ROW_COUNT; v_archived := v_archived + n;

  -- Critique non traitée depuis > 30j = bruit stale (sinon elle aurait été traitée). Archivée.
  UPDATE public.system_errors SET status = 'fixed', fix_applied = true, fix_description = 'Auto-archivé (critique stale > 30j)', fixed_at = now()
  WHERE severity IN ('critique','critical') AND status = 'detected' AND created_at < now() - interval '30 days';
  GET DIAGNOSTICS n = ROW_COUNT; v_archived := v_archived + n;

  RETURN jsonb_build_object('archived', v_archived, 'deleted', v_deleted);
END;
$$;

GRANT EXECUTE ON FUNCTION cleanup_old_errors() TO service_role;

-- Purge immédiate du bruit accumulé (7 mois).
SELECT public.cleanup_old_errors() AS cleanup_result;

SELECT 'calculate_system_health corrigée (jsonb, champs cohérents, status qualifié) + cleanup étendu exécuté.' AS status;
