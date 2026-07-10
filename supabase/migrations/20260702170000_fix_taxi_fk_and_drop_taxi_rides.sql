-- ============================================================================
-- RÉPARE LES FK taxi_ratings/taxi_payments + SUPPRIME `taxi_rides` — TIER 2
-- ----------------------------------------------------------------------------
-- BUG corrigé : taxi_ratings.ride_id et taxi_payments.ride_id avaient une FK vers
-- `taxi_rides` (table vide, remplacée par taxi_trips). Or le code insère un
-- `taxi_trips.id` dans ride_id (taxi.routes.ts, taxi-payment-process/index.ts) →
-- CHAQUE notation et paiement taxi violait la FK et échouait silencieusement
-- (d'où 0 ligne dans les deux tables). On repointe ride_id vers taxi_trips :
-- notation chauffeur + enregistrement paiement taxi redeviennent fonctionnels.
--
-- Vérifié : taxi_ratings = 0 ligne / 0 orphelin, taxi_payments = 0 ligne / 0 orphelin
-- → l'ajout des nouvelles FK ne peut pas échouer sur des données existantes.
-- Après repoint, `taxi_rides` (orpheline code, 0 ligne) n'a plus de dépendant → DROP.
-- ============================================================================

-- 1) taxi_ratings.ride_id : taxi_rides → taxi_trips (notation supprimée si la course l'est)
ALTER TABLE public.taxi_ratings DROP CONSTRAINT IF EXISTS taxi_ratings_ride_id_fkey;
ALTER TABLE public.taxi_ratings
  ADD CONSTRAINT taxi_ratings_ride_id_fkey
  FOREIGN KEY (ride_id) REFERENCES public.taxi_trips(id) ON DELETE CASCADE;

-- 2) taxi_payments.ride_id : taxi_rides → taxi_trips (RESTRICT : on protège le
--    registre des paiements, une course avec paiement ne peut être supprimée).
ALTER TABLE public.taxi_payments DROP CONSTRAINT IF EXISTS taxi_payments_ride_id_fkey;
ALTER TABLE public.taxi_payments
  ADD CONSTRAINT taxi_payments_ride_id_fkey
  FOREIGN KEY (ride_id) REFERENCES public.taxi_trips(id);

-- 3) Plus aucun dépendant vivant → suppression de la table fantôme
DROP TABLE IF EXISTS public.taxi_rides;

-- ── VÉRIFICATIONS ───────────────────────────────────────────────────────────
-- a) taxi_rides n'existe plus (0 ligne)
SELECT c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname = 'taxi_rides';

-- b) les 2 FK pointent bien vers taxi_trips maintenant
SELECT tc.table_name, ccu.table_name AS references_table
FROM information_schema.table_constraints tc
JOIN information_schema.constraint_column_usage ccu
  ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = 'public'
  AND tc.constraint_name IN ('taxi_ratings_ride_id_fkey','taxi_payments_ride_id_fkey');
