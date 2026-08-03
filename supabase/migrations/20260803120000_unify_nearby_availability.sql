-- ═══════════════════════════════════════════════════════════════════════════════
-- RADAR TAXI + COMPTEURS DISPONIBILITÉ — UNE seule définition de « disponible »
-- ═══════════════════════════════════════════════════════════════════════════════
-- Avant : 3 prédicats DIFFÉRENTS pour « chauffeur disponible » →
--   • find_nearby_taxi_drivers (radar)  : is_online AND status IN ('available','active')
--   • count_nearby_services (Accès rapide): is_online AND status IN ('online','available')
--   • get_proximity_stats (Proximité)    : is_online OR status IN ('on_trip','active','online')
-- → le compteur « Taxi 0 » alors que le radar montre un chauffeur (et l'inverse).
--
-- Après : UN prédicat canonique partout = « en ligne ET pas occupé/hors-ligne » :
--   is_online = true AND status NOT IN ('offline','on_trip','busy','suspended','inactive')
-- Robuste aux vocabulaires réels (taxi_drivers.status='available', drivers.status='online'),
-- exclut les occupés ('on_trip'). Le radar, l'Accès rapide et la Proximité comptent IDENTIQUE.
-- Taxi = moto + voiture (aucun filtre de catégorie). Livreur = drivers (idem, sans les taxis).
-- Rayon : 20 km par défaut PARTOUT (déjà aligné dans les 3 fonctions).

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) RADAR — mêmes 2 catégories, prédicat canonique, tri distance. Return inchangé.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.find_nearby_taxi_drivers(p_lat numeric, p_lng numeric, p_radius_km numeric DEFAULT 20, p_limit integer DEFAULT 10, p_taxi_category text DEFAULT NULL::text)
 RETURNS TABLE(driver_id uuid, user_id uuid, distance_km numeric, rating numeric, vehicle_type text, vehicle_plate text, taxi_category text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  SELECT
    td.id AS driver_id,
    td.user_id,
    calculate_distance_km(p_lat, p_lng, td.last_lat, td.last_lng) AS distance_km,
    td.rating,
    td.vehicle_type,
    td.vehicle_plate,
    td.taxi_category
  FROM public.taxi_drivers td
  WHERE
    td.is_online = true
    AND td.status NOT IN ('offline','on_trip','busy','suspended','inactive')
    AND td.last_lat IS NOT NULL
    AND td.last_lng IS NOT NULL
    AND calculate_distance_km(p_lat, p_lng, td.last_lat, td.last_lng) <= p_radius_km
    AND (p_taxi_category IS NULL OR td.taxi_category = p_taxi_category)   -- NULL = moto + voiture
  ORDER BY distance_km ASC, td.rating DESC
  LIMIT p_limit;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) ACCÈS RAPIDE (Home) — taxi + livreur au prédicat canonique.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.count_nearby_services(p_lat double precision, p_lng double precision, p_radius_km double precision DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_boutiques   integer := 0;
  v_taxi        integer := 0;
  v_livraison   integer := 0;
  v_restaurants integer := 0;
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL THEN
    RETURN jsonb_build_object('boutiques', 0, 'taxi', 0, 'livraison', 0, 'restaurants', 0);
  END IF;

  SELECT count(*) INTO v_boutiques
  FROM vendors v
  WHERE v.is_active IS TRUE
    AND v.latitude IS NOT NULL AND v.longitude IS NOT NULL
    AND public._haversine_km(p_lat, p_lng, v.latitude, v.longitude) <= p_radius_km;

  -- Taxis (moto + voiture) DISPONIBLES — prédicat canonique = même que le radar.
  SELECT count(*) INTO v_taxi
  FROM taxi_drivers t
  WHERE t.is_online IS TRUE
    AND t.status NOT IN ('offline','on_trip','busy','suspended','inactive')
    AND t.last_lat IS NOT NULL AND t.last_lng IS NOT NULL
    AND public._haversine_km(p_lat, p_lng, t.last_lat, t.last_lng) <= p_radius_km;

  -- Livreurs DISPONIBLES — même prédicat canonique (exclut les occupés 'on_trip').
  -- current_location est un `point` (x=lng=[0], y=lat=[1]) — pas de cast.
  SELECT count(*) INTO v_livraison
  FROM drivers d
  WHERE d.is_online IS TRUE
    AND d.status NOT IN ('offline','on_trip','busy','suspended','inactive')
    AND d.current_location IS NOT NULL
    AND public._haversine_km(p_lat, p_lng, (d.current_location)[1], (d.current_location)[0]) <= p_radius_km;

  SELECT count(*) INTO v_restaurants
  FROM professional_services ps
  JOIN service_types st ON st.id = ps.service_type_id
  WHERE ps.status = 'active'
    AND st.code = 'restaurant'
    AND ps.latitude IS NOT NULL AND ps.longitude IS NOT NULL
    AND public._haversine_km(p_lat, p_lng, ps.latitude, ps.longitude) <= p_radius_km;

  RETURN jsonb_build_object(
    'boutiques',   COALESCE(v_boutiques, 0),
    'taxi',        COALESCE(v_taxi, 0),
    'livraison',   COALESCE(v_livraison, 0),
    'restaurants', COALESCE(v_restaurants, 0)
  );
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) PROXIMITÉ — mêmes prédicats canoniques pour tx (taxi) et drv (livreur) ;
--    livraison = livreurs SEULS (comme l'Accès rapide, plus les taxis).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_proximity_stats(p_lat numeric, p_lng numeric, p_radius_km numeric DEFAULT 20)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
WITH
vend AS (
  SELECT v.id, v.business_type, v.service_type,
    CASE WHEN v.latitude IS NOT NULL AND v.longitude IS NOT NULL THEN v.latitude::numeric  ELSE cc.latitude::numeric  END AS lat,
    CASE WHEN v.latitude IS NOT NULL AND v.longitude IS NOT NULL THEN v.longitude::numeric ELSE cc.longitude::numeric END AS lng
  FROM public.vendors v
  LEFT JOIN public.city_coordinates cc ON cc.city_key = public.normalize_city_key(v.city)
  WHERE v.is_active = true
),
vend_d AS (
  SELECT *, CASE WHEN lat IS NOT NULL AND lng IS NOT NULL THEN public.calculate_distance_km(p_lat, p_lng, lat, lng) END AS dist FROM vend
),
vend_in AS (SELECT * FROM vend_d WHERE dist IS NOT NULL AND dist <= p_radius_km),

subs AS (SELECT professional_service_id FROM public.get_active_service_subscription_limits()),
svc0 AS (
  SELECT ps.id, st.code,
    CASE WHEN ps.latitude IS NOT NULL AND ps.longitude IS NOT NULL THEN ps.latitude::numeric
         WHEN vm.latitude IS NOT NULL AND vm.longitude IS NOT NULL THEN vm.latitude::numeric ELSE NULL END AS elat,
    CASE WHEN ps.latitude IS NOT NULL AND ps.longitude IS NOT NULL THEN ps.longitude::numeric
         WHEN vm.latitude IS NOT NULL AND vm.longitude IS NOT NULL THEN vm.longitude::numeric ELSE NULL END AS elng,
    COALESCE(NULLIF(btrim(COALESCE(ps.city,'')),''), NULLIF(btrim(COALESCE(vm.city,'')),'')) AS ecity
  FROM public.professional_services ps
  JOIN subs ON subs.professional_service_id = ps.id
  LEFT JOIN public.vendors vm ON vm.user_id = ps.user_id
  LEFT JOIN public.service_types st ON st.id = ps.service_type_id
  WHERE ps.status = 'active'
),
svc AS (
  SELECT s.id, s.code,
    COALESCE(s.elat, cc.latitude::numeric)  AS lat,
    COALESCE(s.elng, cc.longitude::numeric) AS lng
  FROM svc0 s
  LEFT JOIN public.city_coordinates cc ON cc.city_key = public.normalize_city_key(s.ecity)
),
svc_d AS (
  SELECT *, CASE WHEN lat IS NOT NULL AND lng IS NOT NULL THEN public.calculate_distance_km(p_lat, p_lng, lat, lng) END AS dist FROM svc
),
svc_in AS (SELECT * FROM svc_d WHERE dist IS NOT NULL AND dist <= p_radius_km),
svc_counts AS (
  SELECT COALESCE(jsonb_object_agg(code, cnt), '{}'::jsonb) AS m
  FROM (SELECT code, count(*)::int AS cnt FROM svc_in WHERE code IS NOT NULL GROUP BY code) z
),

drv AS (
  SELECT d.id, d.vehicle_type,
    (d.current_location)[1]::numeric AS lat,
    (d.current_location)[0]::numeric AS lng
  FROM public.drivers d
  WHERE d.is_online = true
    AND d.status NOT IN ('offline','on_trip','busy','suspended','inactive')
    AND d.current_location IS NOT NULL
),
drv_d AS (SELECT *, public.calculate_distance_km(p_lat, p_lng, lat, lng) AS dist FROM drv),
drv_in AS (SELECT * FROM drv_d WHERE dist IS NOT NULL AND dist <= p_radius_km),
drv_all AS (SELECT count(*)::int AS total FROM public.drivers WHERE is_online=true AND status NOT IN ('offline','on_trip','busy','suspended','inactive')),

tx AS (
  SELECT t.id, t.last_lat::numeric AS lat, t.last_lng::numeric AS lng
  FROM public.taxi_drivers t
  WHERE t.is_online = true
    AND t.status NOT IN ('offline','on_trip','busy','suspended','inactive')
    AND t.last_lat IS NOT NULL AND t.last_lng IS NOT NULL
),
tx_d AS (SELECT *, public.calculate_distance_km(p_lat, p_lng, lat, lng) AS dist FROM tx),
tx_in AS (SELECT * FROM tx_d WHERE dist IS NOT NULL AND dist <= p_radius_km),
tx_all AS (SELECT count(*)::int AS total FROM public.taxi_drivers WHERE is_online=true AND status NOT IN ('offline','on_trip','busy','suspended','inactive')),

prod AS (
  SELECT p.id, lower(COALESCE(c.name,'')) AS cname
  FROM public.products p
  LEFT JOIN public.categories c ON c.id = p.category_id
  JOIN public.vendors pv ON pv.id = p.vendor_id
  WHERE p.is_active = true
    AND pv.business_type IN ('online','hybrid')
),
prod_counts AS (
  SELECT
    count(DISTINCT id) FILTER (WHERE cname LIKE '%mode%' OR cname LIKE '%vetement%' OR cname LIKE '%fashion%')::int AS mode,
    count(DISTINCT id) FILTER (WHERE cname LIKE '%electron%' OR cname LIKE '%tech%' OR cname LIKE '%phone%' OR cname LIKE '%high-tech%' OR cname LIKE '%informatique%')::int AS electronique,
    count(DISTINCT id) FILTER (WHERE cname LIKE '%maison%' OR cname LIKE '%deco%' OR cname LIKE '%home%')::int AS maison
  FROM prod
)
SELECT jsonb_build_object(
  'stats', jsonb_build_object(
    'boutiques',   (SELECT count(*) FROM vend_in),
    'restaurant',  (SELECT count(*) FROM vend_in WHERE business_type='restaurant' OR service_type='restaurant')
                   + COALESCE((sc.m->>'restaurant')::int, 0),
    'taxiMoto',    (SELECT count(*) FROM tx_in),
    'vtc',         (SELECT count(*) FROM drv_in WHERE vehicle_type='car'),
    'livraison',   (SELECT count(*) FROM drv_in),
    'beaute',      COALESCE((sc.m->>'beaute')::int, 0),
    'reparation',  COALESCE((sc.m->>'reparation')::int, 0),
    'nettoyage',   COALESCE(NULLIF((sc.m->>'menage')::int,0),   NULLIF((sc.m->>'nettoyage')::int,0),  0),
    'immobilier',  COALESCE(NULLIF((sc.m->>'location')::int,0), NULLIF((sc.m->>'immobilier')::int,0), 0),
    'formation',   COALESCE(NULLIF((sc.m->>'education')::int,0),NULLIF((sc.m->>'formation')::int,0),  0),
    'media',       COALESCE(NULLIF((sc.m->>'media')::int,0),    NULLIF((sc.m->>'photo-video')::int,0),0),
    'sante',       COALESCE((sc.m->>'sante')::int,0) + COALESCE((sc.m->>'pharmacie')::int,0),
    'sport',       COALESCE((sc.m->>'sport')::int, 0),
    'informatique',COALESCE(NULLIF((sc.m->>'informatique')::int,0), NULLIF((sc.m->>'tech')::int,0), 0),
    'agriculture', COALESCE((sc.m->>'agriculture')::int, 0),
    'freelance',   COALESCE(NULLIF((sc.m->>'freelance')::int,0),   NULLIF((sc.m->>'administratif')::int,0), 0),
    'construction',COALESCE(NULLIF((sc.m->>'construction')::int,0),NULLIF((sc.m->>'btp')::int,0), 0),
    'plomberie',   COALESCE(NULLIF((sc.m->>'plomberie')::int,0),   NULLIF((sc.m->>'plombier')::int,0), 0),
    'vitrerie',    COALESCE(NULLIF((sc.m->>'vitrerie')::int,0),    NULLIF((sc.m->>'vitrier')::int,0), 0),
    'menuiserie',  COALESCE(NULLIF((sc.m->>'menuiserie')::int,0),  NULLIF((sc.m->>'menuisier')::int,0), 0),
    'soudure',     COALESCE(NULLIF((sc.m->>'soudure')::int,0), NULLIF((sc.m->>'metallerie')::int,0), NULLIF((sc.m->>'soudeur')::int,0), 0),
    'mode',        (SELECT mode FROM prod_counts),
    'electronique',(SELECT electronique FROM prod_counts),
    'maison',      (SELECT maison FROM prod_counts)
  ),
  'by_code', sc.m,
  'debug', jsonb_build_object(
    'vendors',  jsonb_build_object('total',(SELECT count(*) FROM public.vendors WHERE is_active=true),
                  'noGps',(SELECT count(*) FROM vend_d WHERE lat IS NULL OR lng IS NULL),
                  'outOfRadius',(SELECT count(*) FROM vend_d WHERE dist IS NOT NULL AND dist > p_radius_km),
                  'inRadius',(SELECT count(*) FROM vend_in)),
    'services', jsonb_build_object('total',(SELECT count(*) FROM svc0),
                  'noGps',(SELECT count(*) FROM svc WHERE lat IS NULL OR lng IS NULL),
                  'outOfRadius',(SELECT count(*) FROM svc_d WHERE dist IS NOT NULL AND dist > p_radius_km),
                  'inRadius',(SELECT count(*) FROM svc_in)),
    'taxiMoto', jsonb_build_object('total',(SELECT total FROM tx_all),
                  'noGps',(SELECT total FROM tx_all) - (SELECT count(*) FROM tx),
                  'outOfRadius',(SELECT count(*) FROM tx_d WHERE dist IS NOT NULL AND dist > p_radius_km),
                  'inRadius',(SELECT count(*) FROM tx_in)),
    'drivers',  jsonb_build_object('total',(SELECT total FROM drv_all),
                  'noGps',(SELECT total FROM drv_all) - (SELECT count(*) FROM drv),
                  'outOfRadius',(SELECT count(*) FROM drv_d WHERE dist IS NOT NULL AND dist > p_radius_km),
                  'inRadius',(SELECT count(*) FROM drv_in)),
    'positionUsed', jsonb_build_object('latitude', p_lat, 'longitude', p_lng)
  )
)
FROM svc_counts sc;
$function$;
