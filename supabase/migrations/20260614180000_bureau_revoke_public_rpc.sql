-- ============================================================================
-- BUREAU — CORRECTIF : révoquer EXECUTE depuis PUBLIC (le vrai trou)
-- ----------------------------------------------------------------------------
-- La migration 20260614170000 révoquait depuis anon/authenticated, MAIS PostgreSQL
-- accorde EXECUTE à `PUBLIC` par défaut à la création d'une fonction. anon/authenticated
-- héritent de PUBLIC → ils gardaient l'accès (vérifié : RPC encore appelable en anon).
-- On révoque donc depuis PUBLIC, puis on (re)accorde au seul service_role (backend).
--
-- ⚠️ Appliquer APRÈS déploiement du frontend qui passe par /api/v2/bureau/*.
-- Rejouable.
-- ============================================================================

REVOKE EXECUTE ON FUNCTION public.get_bureau_realtime_stats(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_bureau_realtime_stats(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.add_syndicate_member_for_vehicle(uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.add_syndicate_member_for_vehicle(uuid, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.add_vehicle_for_bureau(
  uuid, text, uuid, text, text, text, text, text, integer, text, text, date
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_vehicle_for_bureau(
  uuid, text, uuid, text, text, text, text, text, integer, text, text, date
) TO service_role;

SELECT 'EXECUTE révoqué depuis PUBLIC sur les 3 RPC bureau → service_role uniquement (vraie fermeture).' AS status;
