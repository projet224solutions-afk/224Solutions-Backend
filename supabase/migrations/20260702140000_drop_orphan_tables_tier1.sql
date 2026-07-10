-- ============================================================================
-- SUPPRESSION DES TABLES ORPHELINES — TIER 1 (vides + zéro usage code)
-- ----------------------------------------------------------------------------
-- Chaque table ci-dessous : 0 ligne en base + AUCUN `.from()` TS/Deno (backend
-- src, Edge Functions, frontend) + remplacée par une table canonique vivante.
-- Preuve établie par recensement d'usage (3 agents, 2026-07-02).
--   • transport_rides       → vestige VTC (module professional_services). Canonique
--                             réel du flux course = taxi_trips.
--   • realestate_properties → 1ʳᵉ itération immobilier (migr. 20251223230525),
--     realestate_visits       remplacée par properties / property_visits (migr.
--                             20260307053805, seule câblée dans useRealEstateData).
--
-- DROP sans CASCADE (RESTRICT par défaut) : si une dépendance imprévue existe,
-- l'ordre échoue au lieu de détruire en cascade → on s'arrête et on réévalue.
-- On retire d'abord la table ENFANT (realestate_visits → FK vers
-- realestate_properties) puis la PARENTE.
-- ============================================================================

-- 1) VTC orphelin
DROP TABLE IF EXISTS public.transport_rides;

-- 2) Immobilier 1ʳᵉ itération (enfant puis parent)
DROP TABLE IF EXISTS public.realestate_visits;
DROP TABLE IF EXISTS public.realestate_properties;

-- ── VÉRIFICATION (doit renvoyer 0 ligne : les 3 tables n'existent plus) ──────
SELECT c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
  AND c.relname IN ('transport_rides','realestate_visits','realestate_properties');
