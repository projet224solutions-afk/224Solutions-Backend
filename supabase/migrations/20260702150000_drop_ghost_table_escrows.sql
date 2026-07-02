-- ============================================================================
-- SUPPRESSION DE LA TABLE FANTÔME `escrows` — TIER 2
-- ----------------------------------------------------------------------------
-- `escrows` = 0 ligne alors que le flux escrow réel a 193 lignes dans
-- `escrow_transactions` → preuve que ses seuls écrivains (les routes Node
-- /escrow/create, /escrow/release, /admin-release-funds, /escrow-auto-release,
-- /escrow-dispute, /escrow-refund de edge-functions/payments.routes.ts) ne sont
-- JAMAIS atteints. Le flux canonique = escrow_transactions (RPC create_order_core
-- + Edge Functions Deno escrow-*).
--
-- ⚠️ ORDRE : ces 6 routes ont été neutralisées (410) et DÉPLOYÉES avant ce DROP.
-- Aucune FK entrante vers `escrows`. Pas de CASCADE (RESTRICT) : si une dépendance
-- imprévue existe, l'ordre échoue au lieu de détruire en cascade.
-- ============================================================================

DROP TABLE IF EXISTS public.escrows;

-- ── VÉRIFICATION (doit renvoyer 0 ligne) ────────────────────────────────────
SELECT c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname = 'escrows';
