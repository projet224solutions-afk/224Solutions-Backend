-- ============================================================================
-- ⭐ AVIS PRODUITS NUMÉRIQUES — système complet (table + RPC vérifiée + agrégat serveur)
-- ----------------------------------------------------------------------------
-- Constat : AUCUNE table d'avis n'existait pour les produits numériques, et
-- digital_products.rating / digital_products.reviews_count n'étaient JAMAIS
-- alimentés (valeurs mortes affichées sur la fiche produit).
--
-- On crée digital_product_reviews (1 avis par (user, produit)), réservé aux
-- ACHETEURS RÉELS via RPC SECURITY DEFINER — preuve : une ligne
-- digital_product_purchases payée + accès accordé (la table de preuve d'achat
-- existe déjà). L'agrégat digital_products.rating / reviews_count est recalculé
-- par trigger SERVEUR (recompute_digital_product_rating) — JAMAIS écrit par le client.
--
-- ── Colonnes / statuts RÉELS retenus (types.ts resync live + Payment.tsx) :
--    digital_product_purchases.buyer_id  = auth.uid()      (⚠️ PAS user_id)
--    digital_product_purchases.product_id                  (⚠️ PAS digital_product_id)
--    payment_status : Payment.tsx insère 'completed' ; digital.routes.ts lit 'paid'
--       → on accepte les DEUX ('completed','paid') pour robustesse au drift.
--    access_granted = true (accès effectif accordé).
-- ============================================================================

-- 1) Table des avis produits numériques.
CREATE TABLE IF NOT EXISTS public.digital_product_reviews (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  digital_product_id  uuid NOT NULL REFERENCES public.digital_products(id) ON DELETE CASCADE,
  user_id             uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  rating              int  NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment             text,
  is_verified         boolean NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, digital_product_id)
);

CREATE INDEX IF NOT EXISTS idx_digital_product_reviews_product ON public.digital_product_reviews(digital_product_id);
CREATE INDEX IF NOT EXISTS idx_digital_product_reviews_user    ON public.digital_product_reviews(user_id);

ALTER TABLE public.digital_product_reviews ENABLE ROW LEVEL SECURITY;

-- 2) RLS — lecture publique (avis affichés sur la fiche), INSERT via RPC-only,
--    UPDATE/DELETE = auteur, service_role plein accès.
DROP POLICY IF EXISTS digital_product_reviews_public_read ON public.digital_product_reviews;
CREATE POLICY digital_product_reviews_public_read ON public.digital_product_reviews
  FOR SELECT USING (true);

DROP POLICY IF EXISTS digital_product_reviews_update_self ON public.digital_product_reviews;
CREATE POLICY digital_product_reviews_update_self ON public.digital_product_reviews
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS digital_product_reviews_delete_self ON public.digital_product_reviews;
CREATE POLICY digital_product_reviews_delete_self ON public.digital_product_reviews
  FOR DELETE TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS digital_product_reviews_service_role ON public.digital_product_reviews;
CREATE POLICY digital_product_reviews_service_role ON public.digital_product_reviews
  FOR ALL TO service_role USING (true) WITH CHECK (true);
-- (Pas de policy INSERT pour authenticated → insert direct impossible : RPC-only.)

-- 3) RPC : soumettre / mettre à jour un avis produit numérique VÉRIFIÉ (achat payé).
CREATE OR REPLACE FUNCTION public.submit_digital_product_review(
  p_digital_product_id uuid,
  p_rating             int,
  p_comment            text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_purchased boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'NON_AUTHENTIFIE'; END IF;
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN RAISE EXCEPTION 'NOTE_INVALIDE'; END IF;
  IF p_digital_product_id IS NULL THEN RAISE EXCEPTION 'PRODUIT_INVALIDE'; END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.digital_product_purchases
    WHERE product_id = p_digital_product_id
      AND buyer_id   = v_uid
      AND payment_status::text IN ('completed','paid')
      AND COALESCE(access_granted, false) = true
  ) INTO v_purchased;
  IF NOT v_purchased THEN RAISE EXCEPTION 'ACHAT_REQUIS'; END IF;

  INSERT INTO public.digital_product_reviews (digital_product_id, user_id, rating, comment, is_verified)
  VALUES (p_digital_product_id, v_uid, p_rating, NULLIF(trim(p_comment), ''), true)
  ON CONFLICT (user_id, digital_product_id)
  DO UPDATE SET rating = EXCLUDED.rating, comment = EXCLUDED.comment, is_verified = true, updated_at = now();

  RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_digital_product_review(uuid, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_digital_product_review(uuid, int, text) TO authenticated;

-- 4) Agrégat SERVEUR : digital_products.rating + reviews_count recalculés par trigger.
CREATE OR REPLACE FUNCTION public.recompute_digital_product_rating()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pid uuid := COALESCE(NEW.digital_product_id, OLD.digital_product_id);
BEGIN
  IF v_pid IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;
  UPDATE public.digital_products dp
  SET rating        = COALESCE((SELECT ROUND(AVG(rating)::numeric, 1) FROM public.digital_product_reviews WHERE digital_product_id = v_pid), 0),
      reviews_count = (SELECT COUNT(*) FROM public.digital_product_reviews WHERE digital_product_id = v_pid),
      updated_at    = now()
  WHERE dp.id = v_pid;
  RETURN COALESCE(NEW, OLD);
END;
$$;

-- Trigger interne : non appelable directement via PostgREST.
REVOKE EXECUTE ON FUNCTION public.recompute_digital_product_rating() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_recompute_digital_rating ON public.digital_product_reviews;
CREATE TRIGGER trg_recompute_digital_rating
  AFTER INSERT OR UPDATE OR DELETE ON public.digital_product_reviews
  FOR EACH ROW EXECUTE FUNCTION public.recompute_digital_product_rating();

SELECT 'Avis digitaux : table digital_product_reviews + RPC submit_digital_product_review (achat vérifié) + trigger agrégat digital_products.rating/reviews_count.' AS status;
