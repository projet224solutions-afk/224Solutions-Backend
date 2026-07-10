-- ============================================================================
-- NETTOYAGE DES FONCTIONS FONCTIONNELLES DUPLIQUÉES — LOT 3
-- ----------------------------------------------------------------------------
-- DROP par signature exacte, preuve d'absence d'appelant en commentaire.
-- Idempotent (IF EXISTS).
-- ============================================================================

-- declare_vehicle_stolen ─ GARDÉE : 7 args (p_bureau_id, p_ip_address, p_user_agent)
--   [6 appelants frontend]. DROP la version 4 args : MORTE.
DROP FUNCTION IF EXISTS public.declare_vehicle_stolen(uuid, uuid, text, text);

-- declare_vehicle_recovered ─ GARDÉE : version (p_vehicle_id, p_recovered_by,
--   p_recovery_notes, p_recovery_location) [2 appelants].
-- DROP la version 6 args (p_bureau_id, p_ip_address, p_user_agent) : MORTE.
DROP FUNCTION IF EXISTS public.declare_vehicle_recovered(uuid, uuid, uuid, text, text, text);

-- ship_transfer ─ GARDÉE : 3 args (p_transfer_id, p_shipped_by, p_shipping_notes)
--   [1 appelant : useMultiWarehouse.ts].
-- DROP la version 5 args (p_transport_method, p_transport_reference) : MORTE.
DROP FUNCTION IF EXISTS public.ship_transfer(uuid, uuid, text, text, text);

-- subscribe_driver ─ GARDÉE : version + p_billing_cycle [1 appelant : useDriverSubscription.ts].
-- DROP la version 4 args (sans p_billing_cycle) : MORTE.
DROP FUNCTION IF EXISTS public.subscribe_driver(uuid, text, text, text);

-- track_product_view ─ GARDÉE : 11 args (p_ip_address inet, p_city) [analytics.service.js].
-- DROP la version 10 args (p_ip_address text) : MORTE.
DROP FUNCTION IF EXISTS public.track_product_view(uuid, uuid, uuid, text, text, text, text, text, text, text);

-- track_shop_visit ─ GARDÉE : version inet (p_city, p_entry_page) [analytics.service.js].
-- DROP la version 10 args (p_ip_address text, sans p_city) : MORTE.
DROP FUNCTION IF EXISTS public.track_shop_visit(uuid, uuid, text, text, text, text, text, text, text, text);

-- increment_shared_link_views ─ GARDÉE : version TEXT.
--   Les 2 surcharges (text + varchar) rendaient l'appel AMBIGU pour PostgREST
--   (« could not choose the best candidate ») → 2 Edge Functions (resolve-short-link,
--   short-link) en échec. DROP varchar → l'appel se résout enfin sur TEXT.
DROP FUNCTION IF EXISTS public.increment_shared_link_views(character varying);

-- send_broadcast_message ─ GARDÉE : (p_broadcast_id uuid, p_sender_id uuid)
--   [appelée en interne par create_and_send_broadcast() — confirmé pg_proc.prosrc].
-- DROP la version 1 arg (p_broadcast_id uuid) : MORTE (surcharge résiduelle).
DROP FUNCTION IF EXISTS public.send_broadcast_message(uuid);

-- create_stock_transfer ─ GARDÉE : version SECURITY DEFINER (…, p_items, p_notes,
--   p_created_by, …) = correctif 20260502300000 qui écrit dans source_location_id/
--   destination_location_id (schéma actuel). DROP la version non-SECDEF (ordre
--   p_created_by, p_notes) : elle écrit dans les ANCIENNES colonnes from/to → laisse
--   source/destination NULL → cassée avec le schéma actuel. Corps comparés (2026-07-02).
DROP FUNCTION IF EXISTS public.create_stock_transfer(uuid, uuid, uuid, jsonb, uuid, text, timestamp with time zone);

-- receive_transfer ─ GARDÉE : version SECURITY DEFINER → jsonb (p_items_received,
--   p_received_by) qui délègue à confirm_transfer_reception. DROP la surcharge → boolean
--   (ordre p_received_by, p_items_received), résiduelle. Corps comparés (2026-07-02).
DROP FUNCTION IF EXISTS public.receive_transfer(uuid, uuid, jsonb, text);

-- ────────────────────────────────────────────────────────────────────────────
-- ⚠️ NON DROPPÉES — décision PDG / doublons volontaires :
--
--   • get_trending_products  : (p_days, p_limit) ET (p_limit) TOUTES DEUX utilisées
--       (useTrendingProducts vs useSmartRecommendations + Edge). Garder les deux.
--   • create_agent_wallet    : () = fonction TRIGGER (bindée) + (p_agent_id uuid) = RPC
--       (3 appelants). Deux rôles distincts. Garder les deux.
--   • upsert_service_type    : seulement des appels de migrations historiques (5 args
--       vs 6 args + p_icon), déjà exécutées. Reco : garder la version 6 args (superset).
-- ────────────────────────────────────────────────────────────────────────────

-- ── VÉRIFICATION lot 3 (doit renvoyer uniquement les fonctions volontairement
--    conservées en double : create_agent_wallet, create_stock_transfer,
--    get_trending_products, receive_transfer, upsert_service_type) ────────────
SELECT p.proname, count(*) AS surcharges_restantes
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('declare_vehicle_stolen','declare_vehicle_recovered','ship_transfer',
    'subscribe_driver','track_product_view','track_shop_visit','increment_shared_link_views',
    'send_broadcast_message')
GROUP BY p.proname HAVING count(*) > 1;
