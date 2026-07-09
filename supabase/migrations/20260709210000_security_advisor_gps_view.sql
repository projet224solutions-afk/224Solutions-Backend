-- ============================================================================
-- 🔒 ADVISOR SÉCURITÉ : v_vehicle_unified_gps (Security Definer View) + note RLS
-- ----------------------------------------------------------------------------
-- ALERTE 1 (CRITICAL) — « Security Definer View » sur public.v_vehicle_unified_gps.
-- La vue UNION ALL les positions GPS de vehicle_gps_tracking (syndicat) et
-- taxi_ride_tracking (taxi). En SECURITY DEFINER (défaut historique des vues PG),
-- elle s'exécute avec les droits du PROPRIÉTAIRE → CONTOURNE la RLS des tables
-- sous-jacentes. Or `anon` a le SELECT dessus → un anonyme pouvait lire TOUTES
-- les positions de véhicules (fuite de géolocalisation).
--
-- AUDIT CONSOMMATEURS : `grep v_vehicle_unified_gps` sur les 2 repos (front + back)
-- = AUCUN consommateur. Vue orpheline → aucun écran à casser.
-- Les 4 tables sous-jacentes (vehicle_gps_tracking, taxi_ride_tracking,
-- taxi_drivers, vehicles) ont TOUTES la RLS activée avec policies → une fois la
-- vue en security_invoker, la RLS de l'appelant s'applique correctement.
--
-- FIX :
--   • security_invoker = true  → la vue applique la RLS de l'appelant (plus de bypass).
--   • REVOKE anon + authenticated (write moot sur une vue UNION non modifiable) ;
--     GRANT SELECT authenticated (RLS-filtré, pour un futur écran flotte légitime) ;
--     service_role garde son accès (chemin backend).
--
-- ALERTE 2 (CRITICAL) — « RLS Disabled » sur public.spatial_ref_sys.
-- FAUX POSITIF CONNU : table SYSTÈME de l'extension PostGIS (catalogue des systèmes
-- de référence spatiaux, données publiques standard EPSG). Elle appartient à
-- l'extension, on ne PEUT PAS y activer la RLS (ALTER échouerait / serait écrasé au
-- prochain upgrade PostGIS) et ce n'est pas une donnée applicative sensible.
-- → NON TOUCHÉE VOLONTAIREMENT. L'alerte peut être ignorée sereinement.
-- ============================================================================

-- Idempotent : SET (option) et REVOKE/GRANT sont rejouables sans erreur.
ALTER VIEW public.v_vehicle_unified_gps SET (security_invoker = true);

REVOKE ALL ON public.v_vehicle_unified_gps FROM anon;
REVOKE ALL ON public.v_vehicle_unified_gps FROM authenticated;
GRANT SELECT ON public.v_vehicle_unified_gps TO authenticated;
