-- ============================================================================
-- ⭐ NOTES MOYENNES SERVEUR — PRODUITS & BOUTIQUES (agrégats calculés par trigger)
-- ----------------------------------------------------------------------------
-- Objectif : la note moyenne (rating) et le nombre d'avis (reviews_count /
-- total_reviews) sont TOUJOURS recalculés côté serveur par trigger, jamais écrits
-- par le client.
--
-- ── PRODUITS (products.rating / products.reviews_count) — DÉJÀ SERVEUR ──────────
--   Le recalcul par avis produit est déjà assuré, de façon idempotente, par :
--     • recompute_product_rating()                 (trigger trg_recompute_product_rating,
--                                                    migration 20260618200000) — AFTER
--                                                    INSERT/UPDATE/DELETE sur product_reviews
--     • update_product_rating_from_product_reviews() (triggers
--                                                    trigger_update_product_rating_from_product_reviews_*,
--                                                    migration 20251227221455)
--   Ces deux triggers agrègent AVG(rating)/COUNT(*) sur product_reviews WHERE
--   is_approved = true et mettent à jour products.rating (arrondi 1 déc.) +
--   reviews_count. Conformément à CLAUDE.md (ne pas dupliquer une fonction
--   existante — ÉTENDRE), on NE recrée PAS de 3e trigger produit ici. Le backfill
--   produit a lui aussi déjà été exécuté par ces migrations.
--
-- ── BOUTIQUES (vendors.rating / vendors.total_reviews) — AJOUTÉ ICI ─────────────
--   Constat : le trigger historique update_vendor_rating_trigger (migrations
--   20250928000503 / 20250928000528) est TOUJOURS actif, mais il agrège la table
--   LEGACY public.reviews (vendor_id) — que le flux d'avis actuel N'ÉCRIT PLUS.
--   Les avis boutique réels vivent dans public.vendor_ratings. Résultat :
--   vendors.rating / vendors.total_reviews ne reflètent PAS vendor_ratings.
--   On « recrée sur le même modèle » l'agrégat serveur, mais branché sur la
--   VRAIE table source (vendor_ratings). Le trigger legacy sur `reviews` reste en
--   place (dormant tant que `reviews` n'est pas écrite) — pas de conflit en pratique.
-- ============================================================================

-- 1) ── Fonction d'agrégation boutique : recalcule vendors.rating + total_reviews
CREATE OR REPLACE FUNCTION public.recompute_vendor_rating()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vendor_id uuid;
  v_avg numeric;
  v_cnt integer;
BEGIN
  v_vendor_id := COALESCE(NEW.vendor_id, OLD.vendor_id);
  IF v_vendor_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT AVG(rating)::numeric(3,2), COUNT(*)
  INTO v_avg, v_cnt
  FROM public.vendor_ratings
  WHERE vendor_id = v_vendor_id;

  UPDATE public.vendors
  SET rating = COALESCE(v_avg, 0),
      total_reviews = COALESCE(v_cnt, 0),
      updated_at = now()
  WHERE id = v_vendor_id;

  RETURN NULL;
END;
$$;

-- Trigger interne : ne doit pas être appelable directement via PostgREST.
REVOKE EXECUTE ON FUNCTION public.recompute_vendor_rating() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_recompute_vendor_rating ON public.vendor_ratings;
CREATE TRIGGER trg_recompute_vendor_rating
  AFTER INSERT OR UPDATE OR DELETE ON public.vendor_ratings
  FOR EACH ROW EXECUTE FUNCTION public.recompute_vendor_rating();

-- 2) ── Backfill : recalcule la note de TOUTES les boutiques ayant ≥1 avis boutique
WITH stats AS (
  SELECT
    vendor_id,
    AVG(rating)::numeric(3,2) AS avg_rating,
    COUNT(*)::int            AS review_count
  FROM public.vendor_ratings
  GROUP BY vendor_id
)
UPDATE public.vendors v
SET rating        = COALESCE(s.avg_rating, 0),
    total_reviews = COALESCE(s.review_count, 0),
    updated_at    = now()
FROM stats s
WHERE v.id = s.vendor_id;

SELECT 'Agrégat boutique serveur : trigger trg_recompute_vendor_rating (vendor_ratings -> vendors.rating/total_reviews) + backfill. Agrégat produit déjà serveur (recompute_product_rating).' AS status;
