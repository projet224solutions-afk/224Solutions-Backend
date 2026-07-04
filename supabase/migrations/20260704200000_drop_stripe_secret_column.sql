-- ============================================================================
-- 🔒 SÉCURITÉ — retirer le secret Stripe de la base de données (défense en profondeur)
-- ----------------------------------------------------------------------------
-- La colonne stripe_config.stripe_secret_key contenait une clé sk_live_ (déjà vidée +
-- rotée). Un secret ne doit JAMAIS vivre en base : il vit UNIQUEMENT en process.env côté
-- backend (voir CLAUDE.md). Le code lisait cette colonne en fallback → fallback RETIRÉ
-- (paymentLinks.routes.ts, pos.routes.ts) : Stripe = process.env.STRIPE_SECRET_KEY seul.
--
-- Cette migration :
--   1) vérifie qu'aucune vue/fonction ne référence la colonne (échoue sinon) ;
--   2) supprime la colonne stripe_secret_key ;
--   3) supprime la policy héritée « Configuration Stripe publique » (USING(true)) si
--      résiduelle — ne garder qu'une policy admin/CEO.
--
-- NB : la colonne stripe_publishable_key (clé PUBLIQUE, non secrète) est conservée.
--      webhook_secret est aussi un secret en table → à traiter en suivi (hors périmètre).
-- Migration livrée — NON exécutée.
-- ============================================================================

-- 1) ── Garde-fou : aucune vue/fonction ne doit dépendre de la colonne ────────
DO $$
DECLARE v_refs int;
BEGIN
  -- Vues référençant la colonne
  SELECT count(*) INTO v_refs
  FROM information_schema.view_column_usage
  WHERE table_schema = 'public' AND table_name = 'stripe_config' AND column_name = 'stripe_secret_key';
  IF v_refs > 0 THEN
    RAISE EXCEPTION 'Abandon : % vue(s) référencent stripe_config.stripe_secret_key — les adapter avant le DROP', v_refs;
  END IF;

  -- Fonctions dont le corps mentionne la colonne. prokind='f' UNIQUEMENT : pg_get_functiondef
  -- lève une erreur sur les agrégats (ex. st_memunion PostGIS) — on ne scanne que les fonctions normales.
  SELECT count(*) INTO v_refs
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind = 'f' AND pg_get_functiondef(p.oid) ILIKE '%stripe_secret_key%';
  IF v_refs > 0 THEN
    RAISE EXCEPTION 'Abandon : % fonction(s) référencent stripe_secret_key — les adapter avant le DROP', v_refs;
  END IF;
END $$;

-- 2) ── Supprimer la colonne secrète ─────────────────────────────────────────
ALTER TABLE public.stripe_config DROP COLUMN IF EXISTS stripe_secret_key;

-- 3) ── Nettoyage des policies : retirer toute policy publique/permissive héritée ──
DROP POLICY IF EXISTS "Configuration Stripe publique" ON public.stripe_config;
DROP POLICY IF EXISTS "authenticated_read_stripe_config" ON public.stripe_config;
DROP POLICY IF EXISTS "Public read stripe config" ON public.stripe_config;
-- (La policy d'accès admin/CEO existante reste en place — ne rien recréer ici.)

-- 4) ── Vérification ─────────────────────────────────────────────────────────
SELECT
  CASE WHEN EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'stripe_config' AND column_name = 'stripe_secret_key'
  ) THEN '❌ colonne stripe_secret_key TOUJOURS présente'
    ELSE '✅ colonne stripe_secret_key supprimée' END AS colonne,
  (SELECT count(*) FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'stripe_config'
     AND (qual = 'true' OR qual IS NULL) AND cmd = 'SELECT') AS policies_select_permissives_restantes;
