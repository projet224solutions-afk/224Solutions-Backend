-- ============================================================================
-- 📍 get_proximity_stats — compteurs proximité CÔTÉ SERVEUR (exacts, sans plafond 1000).
-- ----------------------------------------------------------------------------
-- Réplique LIGNE PAR LIGNE la logique de useProximityStats.ts (compteurs + debug) :
--  • Cascade GPS : item → vendeur lié (user_id) → centre-ville (city_coordinates via
--    normalize_city_key), rayon haversine (calculate_distance_km). Rayon 20 km par défaut.
--  • Services pro : ⚠️ ABONNÉS UNIQUEMENT (get_active_service_subscription_limits) — mêmes
--    règles de visibilité que l'annuaire (les compteurs comptent ce que l'utilisateur VERRA).
--  • taxi_drivers comptés en taxiMoto ET livraison (double comptage VOULU : les motos livrent aussi).
--  • produits (mode/électronique/maison) : matching ILIKE sur le nom de catégorie, COUNT DISTINCT,
--    SANS filtre GPS (choix existant conservé).
--  • Alias service_types repris TELS QUELS (menage|nettoyage, location|immobilier, sante+pharmacie…).
--    Sémantique JS `a || b` = premier NON NUL → COALESCE(NULLIF(a,0), NULLIF(b,0), 0). sante = SOMME.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_proximity_stats(
  p_lat numeric, p_lng numeric, p_radius_km numeric DEFAULT 20
)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
WITH
-- ── Boutiques (vendors actifs) : coords = GPS vendeur sinon centre-ville ──
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

-- ── Services pro ABONNÉS : coords = service → vendeur lié → centre-ville ──
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

-- ── Drivers (current_location = point (lng,lat)) ──
drv AS (
  SELECT d.id, d.vehicle_type, (d.current_location[1])::numeric AS lat, (d.current_location[0])::numeric AS lng
  FROM public.drivers d
  WHERE (d.status = 'active' OR d.is_online = true) AND d.current_location IS NOT NULL
),
drv_d AS (SELECT *, public.calculate_distance_km(p_lat, p_lng, lat, lng) AS dist FROM drv),
drv_in AS (SELECT * FROM drv_d WHERE dist IS NOT NULL AND dist <= p_radius_km),
drv_all AS (SELECT count(*)::int AS total FROM public.drivers WHERE (status='active' OR is_online=true)),

-- ── Taxi drivers (last_lat/last_lng) : taxiMoto ET livraison ──
tx AS (
  SELECT t.id, t.last_lat::numeric AS lat, t.last_lng::numeric AS lng
  FROM public.taxi_drivers t
  WHERE (t.is_online = true OR t.status IN ('on_trip','active','online')) AND t.last_lat IS NOT NULL AND t.last_lng IS NOT NULL
),
tx_d AS (SELECT *, public.calculate_distance_km(p_lat, p_lng, lat, lng) AS dist FROM tx),
tx_in AS (SELECT * FROM tx_d WHERE dist IS NOT NULL AND dist <= p_radius_km),
tx_all AS (SELECT count(*)::int AS total FROM public.taxi_drivers WHERE (is_online=true OR status IN ('on_trip','active','online'))),

-- ── Produits (mode/électronique/maison) : ILIKE nom catégorie, COUNT DISTINCT, SANS GPS ──
prod AS (
  SELECT p.id, lower(COALESCE(c.name,'')) AS cname
  FROM public.products p LEFT JOIN public.categories c ON c.id = p.category_id
  WHERE p.is_active = true
),
prod_counts AS (
  SELECT
    count(DISTINCT id) FILTER (WHERE cname LIKE '%mode%' OR cname LIKE '%vetement%' OR cname LIKE '%fashion%')::int AS mode,
    count(DISTINCT id) FILTER (WHERE cname LIKE '%electron%' OR cname LIKE '%tech%' OR cname LIKE '%phone%' OR cname LIKE '%high-tech%' OR cname LIKE '%informatique%')::int AS electronique,
    count(DISTINCT id) FILTER (WHERE cname LIKE '%maison%' OR cname LIKE '%déco%' OR cname LIKE '%home%')::int AS maison
  FROM prod
)
SELECT jsonb_build_object(
  'stats', jsonb_build_object(
    'boutiques',   (SELECT count(*) FROM vend_in),
    'restaurant',  (SELECT count(*) FROM vend_in WHERE business_type='restaurant' OR service_type='restaurant')
                   + COALESCE((sc.m->>'restaurant')::int, 0),
    'taxiMoto',    (SELECT count(*) FROM tx_in),
    'vtc',         (SELECT count(*) FROM drv_in WHERE vehicle_type='car'),
    'livraison',   (SELECT count(*) FROM drv_in) + (SELECT count(*) FROM tx_in),
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
$$;
REVOKE ALL ON FUNCTION public.get_proximity_stats(numeric, numeric, numeric) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_proximity_stats(numeric, numeric, numeric) TO anon, authenticated, service_role;

-- Auto-test (ne doit pas lever).
DO $$ DECLARE r jsonb; BEGIN r := public.get_proximity_stats(9.7085, -13.3856, 20); RAISE NOTICE 'get_proximity_stats OK: %', (r->'stats'->>'boutiques'); END $$;

SELECT 'get_proximity_stats installée (compteurs serveur exacts, visibilité abonnés).' AS status;
