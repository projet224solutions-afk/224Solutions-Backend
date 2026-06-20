-- =====================================================
-- MIGRATION TAXI-MOTO - AJOUT DES FONCTIONS MANQUANTES (FINAL)
-- =====================================================

-- 1. Activer PostGIS
CREATE EXTENSION IF NOT EXISTS postgis;

-- 2. Fonction calcul distance
CREATE OR REPLACE FUNCTION calculate_distance_km(
  lat1 NUMERIC, lng1 NUMERIC, lat2 NUMERIC, lng2 NUMERIC
) RETURNS NUMERIC AS $$
DECLARE
  earth_radius NUMERIC := 6371;
  dlat NUMERIC; dlng NUMERIC; a NUMERIC; c NUMERIC;
BEGIN
  dlat := radians(lat2 - lat1);
  dlng := radians(lng2 - lng1);
  a := sin(dlat/2) * sin(dlat/2) + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlng/2) * sin(dlng/2);
  c := 2 * atan2(sqrt(a), sqrt(1-a));
  RETURN earth_radius * c;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 3. Fonction calcul tarif
CREATE OR REPLACE FUNCTION calculate_taxi_fare(
  p_distance_km NUMERIC,
  p_duration_min INTEGER,
  p_surge_multiplier NUMERIC DEFAULT 1.0
) RETURNS JSONB AS $$
DECLARE
  base_fare NUMERIC := 5000;
  rate_per_km NUMERIC := 1500;
  rate_per_min NUMERIC := 200;
  platform_commission NUMERIC := 0.15;
  fare_before_surge NUMERIC;
  total_fare NUMERIC;
  driver_share NUMERIC;
  platform_fee NUMERIC;
BEGIN
  fare_before_surge := base_fare + (p_distance_km * rate_per_km) + (p_duration_min * rate_per_min);
  total_fare := ROUND(fare_before_surge * p_surge_multiplier);
  platform_fee := ROUND(total_fare * platform_commission);
  driver_share := total_fare - platform_fee;
  
  RETURN jsonb_build_object(
    'total_fare', total_fare,
    'driver_share', driver_share,
    'platform_fee', platform_fee,
    'base_fare', base_fare,
    'distance_charge', ROUND(p_distance_km * rate_per_km),
    'duration_charge', ROUND(p_duration_min * rate_per_min),
    'surge_multiplier', p_surge_multiplier
  );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 4. Fonction recherche conducteurs
DROP FUNCTION IF EXISTS find_nearby_taxi_drivers(NUMERIC, NUMERIC, NUMERIC, INTEGER);

CREATE FUNCTION find_nearby_taxi_drivers(
  p_lat NUMERIC, p_lng NUMERIC, p_radius_km NUMERIC DEFAULT 5.0, p_limit INTEGER DEFAULT 10
) RETURNS TABLE (
  driver_id UUID, user_id UUID, distance_km NUMERIC, rating NUMERIC, vehicle_type TEXT, vehicle_plate TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    td.id, td.user_id,
    calculate_distance_km(p_lat, p_lng, td.last_lat, td.last_lng),
    td.rating, td.vehicle_type, td.vehicle_plate
  FROM taxi_drivers td
  WHERE 
    td.is_online = true AND td.status = 'available'
    AND td.last_lat IS NOT NULL AND td.last_lng IS NOT NULL
    AND calculate_distance_km(p_lat, p_lng, td.last_lat, td.last_lng) <= p_radius_km
  ORDER BY calculate_distance_km(p_lat, p_lng, td.last_lat, td.last_lng) ASC, td.rating DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- 5. Système de locks
CREATE TABLE IF NOT EXISTS taxi_locks (
  resource_type TEXT NOT NULL,
  resource_id UUID NOT NULL,
  locked_by UUID NOT NULL,
  locked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (resource_type, resource_id)
);

CREATE OR REPLACE FUNCTION acquire_taxi_lock(
  p_resource_type TEXT, p_resource_id UUID, p_locked_by UUID, p_timeout_seconds INTEGER DEFAULT 30
) RETURNS BOOLEAN AS $$
DECLARE lock_acquired BOOLEAN;
BEGIN
  DELETE FROM taxi_locks WHERE expires_at < NOW();
  INSERT INTO taxi_locks (resource_type, resource_id, locked_by, expires_at)
  VALUES (p_resource_type, p_resource_id, p_locked_by, NOW() + (p_timeout_seconds || ' seconds')::INTERVAL)
  ON CONFLICT (resource_type, resource_id) DO NOTHING;
  GET DIAGNOSTICS lock_acquired = ROW_COUNT;
  RETURN lock_acquired > 0;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION release_taxi_lock(
  p_resource_type TEXT, p_resource_id UUID, p_locked_by UUID
) RETURNS VOID AS $$
BEGIN
  DELETE FROM taxi_locks WHERE resource_type = p_resource_type AND resource_id = p_resource_id AND locked_by = p_locked_by;
END;
$$ LANGUAGE plpgsql;

-- 6. Fonctions utilitaires
CREATE OR REPLACE FUNCTION create_taxi_notification(
  p_user_id UUID, p_type TEXT, p_title TEXT, p_body TEXT, p_data JSONB DEFAULT '{}', p_ride_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE notification_id UUID;
BEGIN
  INSERT INTO taxi_notifications (user_id, type, title, body, data, ride_id)
  VALUES (p_user_id, p_type, p_title, p_body, p_data, p_ride_id) RETURNING id INTO notification_id;
  RETURN notification_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION log_taxi_action(
  p_action_type TEXT, p_actor_id UUID, p_actor_type TEXT, p_resource_type TEXT, p_resource_id UUID DEFAULT NULL, p_details JSONB DEFAULT '{}'
) RETURNS UUID AS $$
DECLARE log_id UUID;
BEGIN
  INSERT INTO taxi_audit_logs (action_type, actor_id, actor_type, resource_type, resource_id, details)
  VALUES (p_action_type, p_actor_id, p_actor_type, p_resource_type, p_resource_id, p_details) RETURNING id INTO log_id;
  RETURN log_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_driver_rating() RETURNS TRIGGER AS $$
BEGIN
  UPDATE taxi_drivers
  SET rating = (SELECT COALESCE(AVG(rating), 5.0) FROM taxi_ratings WHERE driver_id = NEW.driver_id),
      total_rides = (SELECT COUNT(*) FROM taxi_trips WHERE driver_id = NEW.driver_id AND status = 'completed')
  WHERE id = NEW.driver_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_driver_rating ON taxi_ratings;
CREATE TRIGGER trigger_update_driver_rating AFTER INSERT ON taxi_ratings FOR EACH ROW EXECUTE FUNCTION update_driver_rating();

-- 7. Création automatique profil conducteur
CREATE OR REPLACE FUNCTION create_taxi_driver_profile() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.role = 'taxi' THEN
    INSERT INTO taxi_drivers (user_id, is_online, status, vehicle_type)
    VALUES (NEW.id, false, 'offline', 'moto') ON CONFLICT (user_id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_create_taxi_driver ON profiles;
CREATE TRIGGER trigger_create_taxi_driver AFTER INSERT OR UPDATE OF role ON profiles FOR EACH ROW EXECUTE FUNCTION create_taxi_driver_profile();

-- 8. Créer profils manquants
INSERT INTO taxi_drivers (user_id, is_online, status, vehicle_type)
SELECT id, false, 'offline', 'moto' FROM profiles WHERE role = 'taxi' ON CONFLICT (user_id) DO NOTHING;