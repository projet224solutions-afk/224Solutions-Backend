-- ════════════════════════════════════════════════════════════════════
-- PARTIE 6 — Commission cash via ABONNEMENT : garde à l'acceptation.
-- En cash, la plateforme ne prélève rien par course (l'argent ne transite
-- pas). Le modèle = abonnement chauffeur (driver_subscriptions). On empêche
-- un chauffeur SANS abonnement actif d'accepter — MAIS uniquement si le PDG
-- a activé le flag enforce_driver_subscription (OFF par défaut), pour ne PAS
-- bloquer le taxi tant que les abonnements ne sont pas généralisés.
--
-- update_taxi_trip_status reproduite À L'IDENTIQUE (depuis 20260625) + la
-- garde gated insérée au passage 'accepted'. Champs financiers toujours
-- INTOUCHABLES (v_allowed_extra inchangé). driver_subscriptions : user_id +
-- status='active' + end_date > now() (schéma réel).
-- ════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.taxi_platform_config
  ADD COLUMN IF NOT EXISTS enforce_driver_subscription BOOLEAN NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.update_taxi_trip_status(
  p_ride_id    uuid,
  p_new_status text,
  p_actor_type text DEFAULT 'driver',
  p_extra_data jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_ride     record;
  v_driver_statuses   text[] := ARRAY['accepted','arriving','started','picked_up','in_progress','completed','cancelled'];
  v_customer_statuses text[] := ARRAY['cancelled','cancelled_by_customer'];
  v_allowed_extra     text[] := ARRAY['cancel_reason','distance_km','duration_min'];
  v_ts_col            text;
  v_key               text;
  v_is_driver         boolean;
BEGIN
  IF v_actor_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Non authentifié');
  END IF;

  SELECT id, status, driver_id, customer_id
  INTO v_ride
  FROM public.taxi_trips
  WHERE id = p_ride_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Course introuvable');
  END IF;

  IF p_actor_type = 'driver' THEN
    -- ✅ taxi_trips.driver_id = taxi_drivers.id → on remonte à user_id
    SELECT EXISTS(
      SELECT 1 FROM public.taxi_drivers
      WHERE id = v_ride.driver_id AND user_id = v_actor_id
    ) INTO v_is_driver;
    IF NOT v_is_driver THEN
      RETURN jsonb_build_object('success', false, 'error', 'Non autorisé : pas le chauffeur de cette course');
    END IF;
    IF NOT (p_new_status = ANY(v_driver_statuses)) THEN
      RETURN jsonb_build_object('success', false, 'error', format('Statut "%s" non autorisé (chauffeur)', p_new_status));
    END IF;

    -- ─── PARTIE 6 : garde abonnement chauffeur (config-gated, OFF par défaut) ───
    -- Un chauffeur ne peut accepter une course que s'il a un abonnement ACTIF,
    -- mais SEULEMENT si le PDG a activé enforce_driver_subscription (sinon inerte).
    IF p_new_status = 'accepted'
       AND COALESCE((SELECT enforce_driver_subscription FROM public.taxi_platform_config LIMIT 1), false) THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.driver_subscriptions
        WHERE user_id = v_actor_id AND status = 'active' AND end_date > now()
      ) THEN
        RETURN jsonb_build_object('success', false, 'error', 'ABONNEMENT_REQUIS',
          'message', 'Abonnement chauffeur requis pour accepter des courses.');
      END IF;
    END IF;
  ELSIF p_actor_type = 'customer' THEN
    IF v_ride.customer_id IS DISTINCT FROM v_actor_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'Non autorisé : pas le client de cette course');
    END IF;
    IF NOT (p_new_status = ANY(v_customer_statuses)) THEN
      RETURN jsonb_build_object('success', false, 'error', format('Statut "%s" non autorisé (client)', p_new_status));
    END IF;
  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'actor_type invalide');
  END IF;

  v_ts_col := CASE p_new_status
    WHEN 'accepted'  THEN 'accepted_at'
    WHEN 'started'   THEN 'started_at'
    WHEN 'completed' THEN 'completed_at'
    WHEN 'cancelled' THEN 'cancelled_at'
    WHEN 'cancelled_by_customer' THEN 'cancelled_at'
    ELSE NULL
  END;

  -- Ownership déjà vérifié → update direct sur la course
  UPDATE public.taxi_trips
  SET status = p_new_status, updated_at = NOW()
  WHERE id = p_ride_id;

  IF v_ts_col IS NOT NULL THEN
    EXECUTE format('UPDATE public.taxi_trips SET %I = NOW() WHERE id = $1', v_ts_col) USING p_ride_id;
  END IF;

  IF p_extra_data IS NOT NULL AND p_extra_data <> '{}'::jsonb THEN
    FOR v_key IN SELECT jsonb_object_keys(p_extra_data) LOOP
      IF v_key = ANY(v_allowed_extra) THEN
        EXECUTE format('UPDATE public.taxi_trips SET %I = $1 WHERE id = $2', v_key)
          USING (p_extra_data ->> v_key), p_ride_id;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('success', true, 'ride_id', p_ride_id, 'new_status', p_new_status, 'actor_type', p_actor_type);
END;
$$;

REVOKE ALL ON FUNCTION public.update_taxi_trip_status(uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_taxi_trip_status(uuid, text, text, jsonb) TO authenticated;

DO $$ BEGIN
  RAISE NOTICE '✅ update_taxi_trip_status + garde abonnement gated (enforce_driver_subscription OFF par défaut)';
END; $$;

COMMIT;
