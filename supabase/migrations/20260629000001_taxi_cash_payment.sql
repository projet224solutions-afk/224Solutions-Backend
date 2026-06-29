-- ════════════════════════════════════════════════════════════════════
-- PARTIE 1 — Paiement ESPÈCES d'une course taxi (CASH).
-- Marque la course payée. AUCUN mouvement wallet : le chauffeur a déjà le
-- liquide en main. Gardée (propriété chauffeur OU client de la course) +
-- idempotente. Audit via log_taxi_action (helper existant).
-- Schéma réel : taxi_drivers.user_id, taxi_trips.{status,payment_status,
-- payment_method,completed_at,price_total,driver_id,customer_id}.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.process_taxi_cash_payment(
  p_ride_id    uuid,
  p_actor_type text DEFAULT 'driver'        -- 'driver' | 'customer'
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_ride  record;
BEGIN
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NON_AUTHENTIFIE');
  END IF;

  SELECT id, status, payment_status, driver_id, customer_id, price_total
  INTO v_ride FROM public.taxi_trips WHERE id = p_ride_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'COURSE_INTROUVABLE');
  END IF;

  -- Propriété : chauffeur (via taxi_drivers.user_id) OU client de CETTE course.
  IF p_actor_type = 'driver' THEN
    IF NOT EXISTS (SELECT 1 FROM public.taxi_drivers d
                   WHERE d.id = v_ride.driver_id AND d.user_id = v_actor) THEN
      RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE_CHAUFFEUR');
    END IF;
  ELSIF p_actor_type = 'customer' THEN
    IF v_ride.customer_id IS DISTINCT FROM v_actor THEN
      RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE_CLIENT');
    END IF;
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'ACTEUR_INVALIDE');
  END IF;

  -- La course doit avoir eu lieu (prise en charge effectuée au minimum).
  IF v_ride.status NOT IN ('completed','picked_up','in_progress','started') THEN
    RETURN jsonb_build_object('success', false, 'error', 'COURSE_NON_TERMINEE');
  END IF;

  -- Idempotent : déjà payée.
  IF v_ride.payment_status = 'paid' THEN
    RETURN jsonb_build_object('success', true, 'already_paid', true,
      'payment_method', 'cash', 'paid', true);
  END IF;

  -- ✅ CASH : marquer payée + terminée. AUCUN crédit wallet chauffeur.
  UPDATE public.taxi_trips
  SET payment_status = 'paid',
      payment_method = 'cash',
      status         = 'completed',
      completed_at   = COALESCE(completed_at, now()),
      updated_at     = now()
  WHERE id = p_ride_id;

  -- Audit (non bloquant) via le helper existant.
  BEGIN
    PERFORM public.log_taxi_action(
      'cash_payment_confirmed', v_actor, p_actor_type,
      'taxi_trip', p_ride_id,
      jsonb_build_object('amount', v_ride.price_total, 'actor_type', p_actor_type));
  EXCEPTION WHEN OTHERS THEN NULL; END;

  RETURN jsonb_build_object('success', true, 'payment_method', 'cash', 'paid', true);
END;
$$;

REVOKE ALL ON FUNCTION public.process_taxi_cash_payment(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.process_taxi_cash_payment(uuid, text) TO authenticated, service_role;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname='process_taxi_cash_payment')
  THEN RAISE EXCEPTION 'RPC cash absente'; END IF;
  RAISE NOTICE '✅ process_taxi_cash_payment OK (aucun crédit wallet)';
END; $$;

COMMIT;
