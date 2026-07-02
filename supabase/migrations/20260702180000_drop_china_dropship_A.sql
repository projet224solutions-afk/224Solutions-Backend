-- ============================================================================
-- SUPPRESSION DE L'IMPLÉMENTATION DROPSHIP CHINE « A » (china_*) — TIER 3
-- ----------------------------------------------------------------------------
-- Décision produit : garder l'implémentation B (dropship_china_*, hook
-- useDropshippingChina, composants montés dans DropshippingModule), supprimer A.
-- A = code 100% mort (hooks/composants/type importés nulle part), 10 tables
-- china_* toutes VIDES. Le code frontend A + les refs cascade backend ont été
-- retirés et déployés AVANT cette migration.
--
-- Seule table externe conservée référençant A = `dropship_products` (2 colonnes
-- A-spécifiques `china_import_id`/`china_supplier_id`, non lues par le code =
-- uniquement dans les types générés). On retire ces colonnes (→ supprime les FK
-- externes), puis on droppe le cluster china_* enfant→parent en RESTRICT.
-- ============================================================================

-- 1) Retirer les colonnes A-spécifiques de dropship_products (supprime leurs FK
--    vers china_product_imports / china_suppliers). Colonnes nullables, non lues.
ALTER TABLE public.dropship_products DROP COLUMN IF EXISTS china_import_id;
ALTER TABLE public.dropship_products DROP COLUMN IF EXISTS china_supplier_id;

-- 2) DROP du cluster china_* (toutes vides), enfants d'abord (RESTRICT).
DROP TABLE IF EXISTS public.china_logistics;
DROP TABLE IF EXISTS public.china_price_alerts;
DROP TABLE IF EXISTS public.china_price_syncs;
DROP TABLE IF EXISTS public.china_supplier_scores;
DROP TABLE IF EXISTS public.china_supplier_orders;
DROP TABLE IF EXISTS public.china_product_imports;
DROP TABLE IF EXISTS public.china_dropship_logs;
DROP TABLE IF EXISTS public.china_dropship_reports;
DROP TABLE IF EXISTS public.china_dropship_settings;
DROP TABLE IF EXISTS public.china_suppliers;

-- ── VÉRIFICATION (doit renvoyer 0 ligne : aucune table china_* ne subsiste) ──
SELECT c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname LIKE 'china\_%';
