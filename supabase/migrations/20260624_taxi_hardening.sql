-- ============================================================================
-- BLINDAGE TAXI-MOTO : RPC updateStatus IDOR-proof + config commission + info client
-- ============================================================================
-- Adapté au SCHÉMA RÉEL de la base (vérifié dans types.ts) :
--   taxi_trips      : status, accepted_at, started_at, completed_at, cancelled_at,
--                     cancel_reason, driver_id, customer_id, driver_share,
--                     platform_fee, price_total, payment_status, distance_km,
--                     duration_min, metadata, updated_at  (PAS arriving_at/in_progress_at)
--   taxi_ratings    : user_id, driver_id, stars, ride_id  (PAS customer_id)
--   taxi_notifications gérées côté front via create_taxi_notification (Promise.all)
-- Résout :
--   CRITIQUE 1 : ownership check avant UPDATE (IDOR)
--   CRITIQUE 3 : whitelist stricte de champs (financiers intouchables)
--   ÉLEVÉ 1    : commission lisible côté serveur (table config)
--   ÉLEVÉ 2    : profil + note client en 1 RPC
-- ============================================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. CONFIG PLATEFORME TAXI (commission modifiable par le PDG)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.taxi_platform_config (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_share_rate NUMERIC(5,4) NOT NULL DEFAULT 0.85
                    CHECK (driver_share_rate BETWEEN 0.50 AND 0.99),
  platform_fee_rate NUMERIC(5,4) NOT NULL DEFAULT 0.15
                    CHECK (platform_fee_rate BETWEEN 0.01 AND 0.50),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by        UUID REFERENCES auth.users(id)
);

COMMENT ON TABLE public.taxi_platform_config IS
  'Taux de commission taxi modifiable par le PDG sans déploiement.';

INSERT INTO public.taxi_platform_config (driver_share_rate, platform_fee_rate)
SELECT 0.85, 0.15
WHERE NOT EXISTS (SELECT 1 FROM public.taxi_platform_config);

ALTER TABLE public.taxi_platform_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "taxi_config_read_auth"   ON public.taxi_platform_config;
DROP POLICY IF EXISTS "taxi_config_write_admin" ON public.taxi_platform_config;

CREATE POLICY "taxi_config_read_auth"
  ON public.taxi_platform_config FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "taxi_config_write_admin"
  ON public.taxi_platform_config FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('pdg', 'admin', 'ceo')
  ));

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RPC : update_taxi_trip_status — IDOR-proof + whitelist de champs
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_taxi_trip_status(
  p_ride_id    uuid,
  p_new_status text,
  p_actor_type text DEFAULT 'driver',   -- 'driver' | 'customer'
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
  -- statuts réellement utilisés par l'app (voir useDriverRideActions / useTaxiRides)
  v_driver_statuses   text[] := ARRAY['accepted','arriving','started','picked_up','in_progress','completed','cancelled'];
  v_customer_statuses text[] := ARRAY['cancelled','cancelled_by_customer'];
  -- colonnes EXTRA autorisées (réelles, non financières)
  v_allowed_extra     text[] := ARRAY['cancel_reason','distance_km','duration_min'];
  v_ts_col            text;
  v_key               text;
BEGIN
  IF v_actor_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Non authentifié');
  END IF;

  -- Charger + verrouiller la course
  SELECT id, status, driver_id, customer_id
  INTO v_ride
  FROM public.taxi_trips
  WHERE id = p_ride_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Course introuvable');
  END IF;

  -- Ownership + statut autorisé selon l'acteur
  IF p_actor_type = 'driver' THEN
    IF v_ride.driver_id IS DISTINCT FROM v_actor_id THEN
      RETURN jsonb_build_object('success', false, 'error', 'Non autorisé : pas le chauffeur de cette course');
    END IF;
    IF NOT (p_new_status = ANY(v_driver_statuses)) THEN
      RETURN jsonb_build_object('success', false, 'error', format('Statut "%s" non autorisé (chauffeur)', p_new_status));
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

  -- Timestamp automatique selon le statut (UNIQUEMENT colonnes réelles)
  v_ts_col := CASE p_new_status
    WHEN 'accepted'  THEN 'accepted_at'
    WHEN 'started'   THEN 'started_at'
    WHEN 'completed' THEN 'completed_at'
    WHEN 'cancelled' THEN 'cancelled_at'
    WHEN 'cancelled_by_customer' THEN 'cancelled_at'
    ELSE NULL  -- arriving / picked_up / in_progress : pas de colonne dédiée
  END;

  -- UPDATE de base : status + updated_at (+ ownership re-vérifié dans le WHERE)
  UPDATE public.taxi_trips
  SET status = p_new_status,
      updated_at = NOW()
  WHERE id = p_ride_id
    AND ((p_actor_type = 'driver'   AND driver_id   = v_actor_id)
      OR (p_actor_type = 'customer' AND customer_id = v_actor_id));

  -- Timestamp dédié si la colonne existe pour ce statut
  IF v_ts_col IS NOT NULL THEN
    EXECUTE format('UPDATE public.taxi_trips SET %I = NOW() WHERE id = $1', v_ts_col)
      USING p_ride_id;
  END IF;

  -- Champs EXTRA (whitelist stricte ; financiers JAMAIS modifiables)
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

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. RPC : get_taxi_platform_config
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_taxi_platform_config()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'driver_share_rate', driver_share_rate,
    'platform_fee_rate', platform_fee_rate
  )
  FROM public.taxi_platform_config
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.get_taxi_platform_config() TO authenticated, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. RPC : get_customer_ride_info — profil + note en 1 appel
--    (taxi_ratings utilise user_id, pas customer_id)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_customer_ride_info(p_customer_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_profile    record;
  v_avg_rating numeric;
BEGIN
  SELECT first_name, last_name, phone
  INTO v_profile
  FROM public.profiles
  WHERE id = p_customer_id;

  SELECT COALESCE(AVG(stars), 4.5)
  INTO v_avg_rating
  FROM public.taxi_ratings
  WHERE user_id = p_customer_id;

  RETURN jsonb_build_object(
    'first_name', COALESCE(v_profile.first_name, ''),
    'last_name',  COALESCE(v_profile.last_name, ''),
    'phone',      COALESCE(v_profile.phone, ''),
    'avg_rating', ROUND(COALESCE(v_avg_rating, 4.5)::numeric, 1)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_customer_ride_info(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_customer_ride_info(uuid) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. VÉRIFICATION ATOMIQUE
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_cfg boolean; v_upd boolean; v_getcfg boolean; v_info boolean;
BEGIN
  SELECT EXISTS(SELECT 1 FROM public.taxi_platform_config) INTO v_cfg;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'update_taxi_trip_status') INTO v_upd;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'get_taxi_platform_config') INTO v_getcfg;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'get_customer_ride_info') INTO v_info;

  IF NOT (v_cfg AND v_upd AND v_getcfg AND v_info) THEN
    RAISE EXCEPTION 'ÉCHEC ATOMICITÉ TAXI — config=% update=% getcfg=% info=%', v_cfg, v_upd, v_getcfg, v_info;
  END IF;
  RAISE NOTICE '✅ MIGRATION TAXI OK — config + 3 RPC créées';
END;
$$;

COMMIT;
