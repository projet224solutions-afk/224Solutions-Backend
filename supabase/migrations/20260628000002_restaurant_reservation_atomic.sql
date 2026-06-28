-- ============================================================================
-- RÉSERVATION RESTAURANT ATOMIQUE — anti double-booking.
--
-- L'ancien flux vérifiait la capacité PUIS insérait, SANS verrou → deux clients
-- réservant le dernier créneau simultanément passaient tous les deux (sur-
-- réservation). Ici : verrou advisory sur (service, date, heure) + vérif capacité
-- + insert dans UNE transaction → les réservations concurrentes du MÊME créneau
-- sont sérialisées.
--
-- NB schéma : la colonne de remarque de restaurant_reservations s'appelle
-- `special_requests` (PAS `notes`). On lit la clé 'notes' du jsonb (envoyée par
-- le front) et on l'écrit dans special_requests.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.create_restaurant_reservation_atomic(
  p_service_id  uuid,
  p_reservation jsonb   -- { customer_name, customer_phone, customer_email,
                        --   reservation_date, reservation_time, party_size,
                        --   table_number, notes }
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_date     date := (p_reservation->>'reservation_date')::date;
  v_time     time := (p_reservation->>'reservation_time')::time;
  v_party    int  := GREATEST(1, COALESCE((p_reservation->>'party_size')::int, 2));
  v_capacity int;
  v_booked   int;
  v_lock_key bigint;
  v_res_id   uuid;
BEGIN
  IF p_service_id IS NULL OR v_date IS NULL OR v_time IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PARAMS_INVALIDES');
  END IF;

  -- ✅ Verrou advisory sur le créneau (service+date+heure) : sérialise les
  -- réservations concurrentes du MÊME créneau. hashtext → bigint stable.
  v_lock_key := hashtext(p_service_id::text || v_date::text || v_time::text);
  PERFORM pg_advisory_xact_lock(v_lock_key);

  -- Capacité totale du restaurant (somme des places des tables actives en service)
  SELECT COALESCE(sum(capacity), 0) INTO v_capacity
  FROM public.restaurant_tables
  WHERE professional_service_id = p_service_id
    AND is_active IS TRUE
    AND COALESCE(status, '') <> 'cleaning';

  -- Pas de tables définies → pas de blocage capacité (fallback large)
  IF v_capacity = 0 THEN v_capacity := 9999; END IF;

  -- Places déjà réservées sur ce créneau (réservations non annulées)
  SELECT COALESCE(sum(party_size), 0) INTO v_booked
  FROM public.restaurant_reservations
  WHERE professional_service_id = p_service_id
    AND reservation_date = v_date
    AND reservation_time = v_time
    AND COALESCE(status, '') NOT IN ('cancelled', 'no_show');

  -- ✅ Vérif capacité ATOMIQUE (sous verrou) avant insert
  IF v_booked + v_party > v_capacity THEN
    RETURN jsonb_build_object(
      'success', false, 'error', 'CRENEAU_COMPLET',
      'capacity', v_capacity, 'booked', v_booked, 'requested', v_party
    );
  END IF;

  -- Insert (toujours sous verrou → pas de course)
  INSERT INTO public.restaurant_reservations (
    professional_service_id, customer_name, customer_phone, customer_email,
    reservation_date, reservation_time, party_size, table_number, status,
    special_requests, created_at
  )
  VALUES (
    p_service_id,
    COALESCE(NULLIF(p_reservation->>'customer_name', ''), 'Client'),
    NULLIF(p_reservation->>'customer_phone', ''),
    NULLIF(p_reservation->>'customer_email', ''),
    v_date, v_time, v_party,
    NULLIF(p_reservation->>'table_number', ''),
    'confirmed',
    NULLIF(p_reservation->>'notes', ''),
    now()
  )
  RETURNING id INTO v_res_id;

  RETURN jsonb_build_object('success', true, 'reservation_id', v_res_id);
  -- Le verrou advisory_xact se libère automatiquement en fin de transaction.

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.create_restaurant_reservation_atomic(uuid, jsonb) FROM anon;
GRANT  EXECUTE ON FUNCTION public.create_restaurant_reservation_atomic(uuid, jsonb) TO authenticated, service_role;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='create_restaurant_reservation_atomic')
  THEN RAISE EXCEPTION 'RPC réservation atomique absente'; END IF;
  RAISE NOTICE '✅ Migration restaurant_reservation_atomic OK';
END; $$;

COMMIT;
