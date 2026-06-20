-- ============================================================================
-- BUREAU SYNDICAT — fermeture de la faille d'isolation (RPC ouvertes à anon)
-- ----------------------------------------------------------------------------
-- AVANT : get_bureau_realtime_stats / add_vehicle_for_bureau /
-- add_syndicate_member_for_vehicle étaient GRANT à `anon` et prenaient un bureau_id
-- du client → n'importe quel anonyme lisait/écrivait les données de TOUS les bureaux.
--
-- DÉSORMAIS ces RPC ne sont appelées que par le BACKEND (service_role), après
-- validation du JWT bureau (le bureau_id vient du token, jamais du client).
--
-- ⚠️ ORDRE D'APPLICATION : appliquer cette migration UNIQUEMENT APRÈS avoir déployé
-- le frontend qui passe par /api/v2/bureau/* (sinon le dashboard bureau, qui appelait
-- ces RPC en anon, cesserait de fonctionner). service_role conserve l'accès.
-- Rejouable.
-- ============================================================================

REVOKE EXECUTE ON FUNCTION public.get_bureau_realtime_stats(uuid) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.get_bureau_realtime_stats(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.add_syndicate_member_for_vehicle(uuid, text) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.add_syndicate_member_for_vehicle(uuid, text) TO service_role;

REVOKE EXECUTE ON FUNCTION public.add_vehicle_for_bureau(
  uuid, text, uuid, text, text, text, text, text, integer, text, text, date
) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.add_vehicle_for_bureau(
  uuid, text, uuid, text, text, text, text, text, integer, text, text, date
) TO service_role;

SELECT 'Grants anon révoqués sur les RPC bureau (stats/véhicule/membre) → backend/service_role uniquement.' AS status;
