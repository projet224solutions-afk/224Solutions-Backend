-- ════════════════════════════════════════════════════════════════════
-- PARTIE 2 — Annulation cadrée d'une course taxi (qui/quand/conséquence).
-- En CASH aucun débit réel : cancel_fee reste INFORMATIF (fiabilité/suivi).
-- accepted_at existe déjà (posé par update_taxi_trip_status à l'acceptation).
-- Vraie colonne raison = cancel_reason. Audit via log_taxi_action.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.taxi_trips
  ADD COLUMN IF NOT EXISTS cancelled_by TEXT CHECK (cancelled_by IN ('driver','customer','system')),
  ADD COLUMN IF NOT EXISTS cancel_fee   NUMERIC DEFAULT 0;

CREATE OR REPLACE FUNCTION public.cancel_taxi_trip(
  p_ride_id    uuid,
  p_actor_type text,
  p_reason     text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_actor      uuid := auth.uid();
  v_ride       record;
  v_new_status text;
  v_fee        numeric := 0;
  v_late       boolean := false;
BEGIN
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NON_AUTHENTIFIE');
  END IF;

  SELECT id, status, driver_id, customer_id, payment_status, accepted_at, price_total
  INTO v_ride FROM public.taxi_trips WHERE id = p_ride_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'COURSE_INTROUVABLE');
  END IF;

  IF v_ride.status = 'completed' OR v_ride.payment_status = 'paid' THEN
    RETURN jsonb_build_object('success', false, 'error', 'COURSE_DEJA_TERMINEE');
  END IF;
  IF v_ride.status IN ('cancelled','cancelled_by_customer') THEN
    RETURN jsonb_build_object('success', true, 'already_cancelled', true);
  END IF;

  -- Annulation TARDIVE = chauffeur déjà engagé (accepté il y a > 2 min + en route).
  v_late := v_ride.accepted_at IS NOT NULL
            AND v_ride.accepted_at < now() - interval '2 minutes'
            AND v_ride.status IN ('accepted','arriving');

  IF p_actor_type = 'customer' THEN
    IF v_ride.customer_id IS DISTINCT FROM v_actor THEN
      RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE_CLIENT');
    END IF;
    v_new_status := 'cancelled_by_customer';
    -- CASH : cancel_fee informatif uniquement (aucun prélèvement réel possible).
    IF v_late THEN v_fee := 0; END IF;
  ELSIF p_actor_type = 'driver' THEN
    IF NOT EXISTS (SELECT 1 FROM public.taxi_drivers d
                   WHERE d.id = v_ride.driver_id AND d.user_id = v_actor) THEN
      RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE_CHAUFFEUR');
    END IF;
    v_new_status := 'cancelled';
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'ACTEUR_INVALIDE');
  END IF;

  UPDATE public.taxi_trips
  SET status       = v_new_status,
      cancelled_by  = p_actor_type,
      cancel_reason = COALESCE(p_reason, cancel_reason),
      cancel_fee    = v_fee,
      cancelled_at  = now(),
      updated_at    = now()
  WHERE id = p_ride_id;

  BEGIN
    PERFORM public.log_taxi_action(
      'ride_cancelled', v_actor, p_actor_type,
      'taxi_trip', p_ride_id,
      jsonb_build_object('by', p_actor_type, 'reason', p_reason, 'late', v_late));
  EXCEPTION WHEN OTHERS THEN NULL; END;

  RETURN jsonb_build_object('success', true, 'status', v_new_status, 'late', v_late);
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_taxi_trip(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.cancel_taxi_trip(uuid, text, text) TO authenticated, service_role;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname='cancel_taxi_trip')
  THEN RAISE EXCEPTION 'RPC cancel_taxi_trip absente'; END IF;
  RAISE NOTICE '✅ cancel_taxi_trip OK';
END; $$;

COMMIT;
