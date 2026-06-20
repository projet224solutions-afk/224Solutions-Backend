-- ================================================================
-- MIGRATION : Supprimer l'ancienne surcharge de create_order_core
--
-- Problème : deux surcharges coexistent en DB :
--   1. Sans p_exchange_rate_used (ancienne — créée par 20260517900000)
--   2. Avec p_exchange_rate_used  (nouvelle — créée par 20260518950000)
-- PostgreSQL retourne "could not choose best candidate" → toutes les
-- commandes marketplace échouent avec HTTP 500.
--
-- Fix : DROP uniquement l'ancienne signature (sans le paramètre).
-- La nouvelle (20260518950000) reste intacte.
-- ================================================================

DROP FUNCTION IF EXISTS public.create_order_core(
  text, uuid, uuid, uuid, text, text, jsonb, text, jsonb, integer, uuid, numeric, text
);

SELECT 'Ancienne surcharge create_order_core (sans p_exchange_rate_used) supprimée.' AS status;
