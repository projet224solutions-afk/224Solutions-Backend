-- ============================================================================
-- SUPPRESSION DE LA TABLE FANTÔME `rides` — TIER 2
-- ----------------------------------------------------------------------------
-- `rides` = 0 ligne. Flux taxi réel = `taxi_trips` (Edge Functions
-- taxi-accept-ride / taxi-refuse-ride, appelées par le front via functions.invoke).
--   • Écrivains neutralisés (410) + déployés : misc.routes.ts /taxi/accept-ride,
--     /taxi/refuse-ride (doublons morts ; front → Edge Deno → taxi_trips).
--   • Lecteur Edge `get-user-activity` repointé vers taxi_trips (colonnes identiques
--     customer_id/driver_id/created_at). Résilient même avant redéploiement Edge :
--     l'erreur « relation rides n'existe pas » n'est pas vérifiée → data null → liste
--     vide (= comportement actuel, rides étant vide). Aucune régression.
--   • Reste `useRides` (frontend useSupabaseQuery.tsx) = CODE MORT (jamais importé).
--
-- Pas de FK entrante vers `rides`. RESTRICT (pas de CASCADE) : si une dépendance
-- imprévue existe (ex. policy d'une autre table), l'ordre échoue → on la traite.
-- ============================================================================

DROP TABLE IF EXISTS public.rides;

-- ── VÉRIFICATION (doit renvoyer 0 ligne) ────────────────────────────────────
SELECT c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname = 'rides';
