-- ════════════════════════════════════════════════════════════════════
-- VÉRIFICATION ATOMIQUE — objets RÉELLEMENT déployés le 25/06/2026
-- (adapté : ne vérifie QUE ce qui a été créé — batch_notify/GPS unifié/
--  triggers véhicule volé n'ont pas été implémentés, donc non vérifiés)
-- ════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE missing text[] := ARRAY[]::text[];
BEGIN
  -- RPC taxi hardening
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='update_taxi_trip_status') THEN missing := missing || 'RPC:update_taxi_trip_status'; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='get_taxi_platform_config') THEN missing := missing || 'RPC:get_taxi_platform_config'; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='get_customer_ride_info')  THEN missing := missing || 'RPC:get_customer_ride_info';  END IF;

  -- Table config commission
  IF NOT EXISTS(SELECT 1 FROM pg_tables WHERE tablename='taxi_platform_config') THEN missing := missing || 'TABLE:taxi_platform_config'; END IF;

  -- Lieux locaux auto-appris
  IF NOT EXISTS(SELECT 1 FROM pg_tables WHERE tablename='local_places')        THEN missing := missing || 'TABLE:local_places'; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='learn_local_place')       THEN missing := missing || 'RPC:learn_local_place'; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='search_local_places')     THEN missing := missing || 'RPC:search_local_places'; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='trg_taxi_learn_dropoff') THEN missing := missing || 'TRIGGER:trg_taxi_learn_dropoff'; END IF;

  -- Colonne cancel_reason
  IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='taxi_trips' AND column_name='cancel_reason')
    THEN missing := missing || 'COL:taxi_trips.cancel_reason'; END IF;

  IF array_length(missing,1) > 0 THEN
    RAISE EXCEPTION E'CORRECTIONS INCOMPLÈTES (%/9) :\n  %', 9 - array_length(missing,1), array_to_string(missing, E'\n  ');
  END IF;
  RAISE NOTICE '✅ TOUTES LES CORRECTIONS DÉPLOYÉES VALIDÉES (9/9)';
END;
$$;

-- Idempotent : s'assurer que cancel_reason existe
ALTER TABLE public.taxi_trips ADD COLUMN IF NOT EXISTS cancel_reason TEXT;

COMMIT;
