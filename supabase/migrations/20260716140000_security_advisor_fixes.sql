-- =============================================================================
-- Correctifs Security Advisor Supabase (digest du 12 juillet 2026)
-- =============================================================================
-- Deux corrections À FAIBLE RISQUE, ciblées, non cassantes :
--
--   1. materialized_view_in_api  (WARN x3)
--      mv_anomalies_summary / mv_system_health / mv_rules_statistics étaient
--      LISIBLES par `anon` et `authenticated` (relacl = anon=arwd.../authenticated=arwd...)
--      → un visiteur anonyme pouvait lire les agrégats de SURVEILLANCE (anomalies,
--      santé système, statistiques de règles). Aucun code client ne consomme ces
--      vues (elles n'apparaissent que dans types.ts généré) : la révocation ne
--      casse rien. Le backend lit via service_role → conservé.
--
--   2. function_search_path_mutable  (WARN x12)
--      12 fonctions sans `search_path` figé → risque d'injection via search_path
--      (surtout pour la SECURITY DEFINER `audit_money_function_ddl`). On fige
--      `search_path = public, pg_temp` : pg_catalog reste implicitement premier
--      (fonctions math/texte OK), les objets publics (dont PostGIS) résolvent,
--      et le linter est satisfait. Aucune réécriture de corps → non cassant.
--
-- NON traités ici (volontairement — voir note de session) :
--   - spatial_ref_sys (ERROR rls_disabled) : table de référence PostGIS possédée
--     par supabase_admin, non modifiable par nous, données publiques sans
--     sensibilité (définitions de systèmes de coordonnées). Faux-positif connu.
--   - public_bucket_allows_listing (x11) : buckets d'assets PUBLICS voulus
--     (images produits/avatars/annonces) — les passer en privé casserait l'affichage.
--   - extension_in_public (postgis, pg_net) : déplacement de schéma = risque de
--     casse élevé pour un gain cosmétique.
--   - *_security_definer_function_executable / auth_allow_anonymous_sign_ins /
--     rls_policy_always_true / rls_enabled_no_policy : structurels et en grande
--     partie INTENTIONNELS (RPC légitimes appelables par authenticated, catalogues
--     publics, tables backend-only) — traités au cas par cas, pas en masse.
-- =============================================================================

BEGIN;

-- 1) Vues matérialisées de surveillance : plus d'accès anon/authenticated.
REVOKE ALL ON public.mv_anomalies_summary FROM anon, authenticated;
REVOKE ALL ON public.mv_system_health    FROM anon, authenticated;
REVOKE ALL ON public.mv_rules_statistics FROM anon, authenticated;

-- 2) Fige le search_path des 12 fonctions signalées (non cassant).
ALTER FUNCTION public._clip_touch_updated_at()                                                     SET search_path = public, pg_temp;
ALTER FUNCTION public._delivery_earning(p_earning numeric, p_fee numeric)                          SET search_path = public, pg_temp;
ALTER FUNCTION public._delivery_is_cash(p_method text)                                             SET search_path = public, pg_temp;
ALTER FUNCTION public._haversine_km(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision) SET search_path = public, pg_temp;
ALTER FUNCTION public.agent_cash_ledger_immutable()                                                SET search_path = public, pg_temp;
ALTER FUNCTION public.audit_money_function_ddl()                                                   SET search_path = public, pg_temp;
ALTER FUNCTION public.freight_rates_touch_updated_at()                                             SET search_path = public, pg_temp;
ALTER FUNCTION public.normalize_city_key(p_city text)                                              SET search_path = public, pg_temp;
ALTER FUNCTION public.normalize_place_name(p text)                                                 SET search_path = public, pg_temp;
ALTER FUNCTION public.set_meeting_number()                                                         SET search_path = public, pg_temp;
ALTER FUNCTION public.set_reserve_number()                                                         SET search_path = public, pg_temp;
ALTER FUNCTION public.touch_clinic_patients_updated_at()                                           SET search_path = public, pg_temp;

COMMIT;
