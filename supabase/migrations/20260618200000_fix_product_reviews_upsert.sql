-- ============================================================================
-- ⭐ FIX AVIS PRODUIT — l'upsert échouait (pas de contrainte UNIQUE) + note non agrégée.
-- ----------------------------------------------------------------------------
-- BUG : ProductRatingDialog fait `upsert(... onConflict: 'user_id,product_id')` sur
-- product_reviews, mais la table n'a AUCUNE contrainte UNIQUE(user_id, product_id) →
-- Postgres rejette l'ON CONFLICT → l'avis produit échoue toujours (l'avis boutique via
-- vendor_ratings = insert simple, marche). De plus la maj `products.rating`/`reviews_count`
-- par le client est refusée par RLS (silencieux) → note produit jamais recalculée.
--
-- FIX : (1) dédoublonnage + contrainte UNIQUE(user_id, product_id) → l'upsert fonctionne.
--       (2) trigger SECURITY DEFINER qui recalcule products.rating + reviews_count à chaque
--           avis (insert/update/delete) → agrégation fiable sans dépendre du client.
-- ============================================================================

-- 1) ── Dédoublonner (garder l'avis le PLUS RÉCENT par user × produit) ────────
DELETE FROM public.product_reviews pr
WHERE pr.id NOT IN (
  SELECT DISTINCT ON (user_id, product_id) id
  FROM public.product_reviews
  ORDER BY user_id, product_id, COALESCE(updated_at, created_at) DESC
);

-- 2) ── Contrainte UNIQUE pour l'upsert onConflict(user_id, product_id) ───────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.product_reviews'::regclass
      AND conname = 'uq_product_reviews_user_product'
  ) THEN
    ALTER TABLE public.product_reviews
      ADD CONSTRAINT uq_product_reviews_user_product UNIQUE (user_id, product_id);
  END IF;
END $$;

-- 3) ── Agrégation serveur : recalcule products.rating + reviews_count ────────
CREATE OR REPLACE FUNCTION public.recompute_product_rating()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_pid uuid; v_avg numeric; v_cnt int;
BEGIN
  v_pid := COALESCE(NEW.product_id, OLD.product_id);
  IF v_pid IS NULL THEN RETURN NULL; END IF;

  SELECT round(avg(rating)::numeric, 1), count(*)
  INTO v_avg, v_cnt
  FROM public.product_reviews
  WHERE product_id = v_pid AND COALESCE(is_approved, true) = true;

  -- Défensif : si les colonnes n'existent pas, on n'échoue pas l'avis.
  BEGIN
    UPDATE public.products
    SET rating = COALESCE(v_avg, 0), reviews_count = COALESCE(v_cnt, 0), updated_at = now()
    WHERE id = v_pid;
  EXCEPTION WHEN undefined_column THEN NULL;
  END;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_recompute_product_rating ON public.product_reviews;
CREATE TRIGGER trg_recompute_product_rating
  AFTER INSERT OR UPDATE OR DELETE ON public.product_reviews
  FOR EACH ROW EXECUTE FUNCTION public.recompute_product_rating();

-- 4) ── Backfill : recalcule la note de tous les produits déjà notés ─────────
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT DISTINCT product_id FROM public.product_reviews LOOP
    BEGIN
      UPDATE public.products p
      SET rating = COALESCE((SELECT round(avg(rating)::numeric,1) FROM public.product_reviews WHERE product_id = r.product_id AND COALESCE(is_approved,true)=true), 0),
          reviews_count = COALESCE((SELECT count(*) FROM public.product_reviews WHERE product_id = r.product_id AND COALESCE(is_approved,true)=true), 0),
          updated_at = now()
      WHERE p.id = r.product_id;
    EXCEPTION WHEN undefined_column THEN NULL;
    END;
  END LOOP;
END $$;

SELECT 'Avis produit réparé : contrainte UNIQUE(user_id,product_id) ajoutée (upsert OK) + agrégation note par trigger serveur + backfill.' AS status;
