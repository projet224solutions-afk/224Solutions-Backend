-- ============================================================================
-- NETTOYAGE DES FONCTIONS DE SÉCURITÉ / VERROUS DUPLIQUÉES — LOT 2
-- ----------------------------------------------------------------------------
-- DROP par signature exacte, preuve d'absence d'appelant en commentaire.
-- Idempotent (IF EXISTS).
-- ============================================================================

-- ⚠️ is_admin ET is_admin_or_pdg : AUCUN DROP ICI (décision PDG requise).
--   • is_admin : is_admin() est appelée par ~21 policies, is_admin(uuid) par ~8 →
--     LES DEUX vivantes. De plus is_admin() n'a AUCUNE définition traçable dans les
--     1197 migrations (présente en base sans source) → dropper = casser 21 policies.
--   • is_admin_or_pdg : is_admin_or_pdg() lit profiles.role, is_admin_or_pdg(uuid) lit
--     pdg_management → SÉMANTIQUEMENT DIFFÉRENTES (142 usages avec-arg, 25 sans-arg).
--     Non interchangeables : aligner = risque de faille/blocage. À traiter à part.

-- acquire_taxi_lock / release_taxi_lock ─ GARDÉE : la paire TEXT / SECURITY DEFINER.
--   Unique appelant = Edge taxi-accept-ride/index.ts (acquire L49 + release L157) avec
--   lockId = 'driver_<uuid>' de type TEXT et clé p_ttl_seconds → paire A cohérente.
-- DROP la paire UUID (p_locked_by uuid / p_timeout_seconds) : MORTE des deux côtés.
DROP FUNCTION IF EXISTS public.acquire_taxi_lock(text, uuid, uuid, integer);
DROP FUNCTION IF EXISTS public.release_taxi_lock(text, uuid, uuid);

-- ── VÉRIFICATION taxi-lock (doit renvoyer 0 ligne) ──────────────────────────
SELECT p.proname, count(*) AS surcharges_restantes
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('acquire_taxi_lock','release_taxi_lock')
GROUP BY p.proname HAVING count(*) > 1;
