-- ============================================================================
-- AVIS RESTAURANT — anti multi-vote + avis VÉRIFIÉ (lié à une vraie commande).
--
-- Avant : un client pouvait poster PLUSIEURS avis sur le même service (aucune contrainte
-- unique ; le garde « déjà noté » n'était qu'un état frontend) → total_reviews gonflé et
-- moyenne biaisée. De plus l'avis n'était pas relié à un achat → un client pouvait noter
-- un restaurant où il n'a jamais commandé (insert direct via API).
--
-- Fix : (1) 1 avis par (service, client) garanti en base ; (2) RPC qui n'autorise l'avis
-- restaurant QUE si le client a une commande terminée/livrée pour ce restaurant, et marque
-- l'avis is_verified=true. L'upsert met à jour l'avis existant (le client peut corriger sa note).
-- ============================================================================

-- 1) Dédoublonnage préalable : garder l'avis le PLUS RÉCENT par (service, client).
DELETE FROM public.service_reviews a
USING public.service_reviews b
WHERE a.client_id IS NOT NULL
  AND a.professional_service_id = b.professional_service_id
  AND a.client_id = b.client_id
  AND (a.created_at < b.created_at OR (a.created_at = b.created_at AND a.id < b.id));

-- 2) Unicité : un seul avis par client et par service.
CREATE UNIQUE INDEX IF NOT EXISTS uniq_service_reviews_client_service
  ON public.service_reviews (professional_service_id, client_id)
  WHERE client_id IS NOT NULL;

-- 3) RPC : soumettre/mettre à jour un avis restaurant VÉRIFIÉ.
CREATE OR REPLACE FUNCTION public.submit_restaurant_review(
  p_service_id uuid,
  p_rating     int,
  p_comment    text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_has_order boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'NON_AUTHENTIFIE'; END IF;
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN RAISE EXCEPTION 'NOTE_INVALIDE'; END IF;

  -- Achat vérifié : le client doit avoir au moins une commande terminée/livrée sur ce restaurant.
  SELECT EXISTS (
    SELECT 1 FROM public.restaurant_orders
    WHERE professional_service_id = p_service_id
      AND customer_user_id = v_uid
      AND status IN ('completed', 'delivered')
  ) INTO v_has_order;
  IF NOT v_has_order THEN RAISE EXCEPTION 'AUCUNE_COMMANDE'; END IF;

  INSERT INTO public.service_reviews (professional_service_id, client_id, rating, comment, is_verified)
  VALUES (p_service_id, v_uid, p_rating, NULLIF(trim(p_comment), ''), true)
  ON CONFLICT (professional_service_id, client_id) WHERE client_id IS NOT NULL
  DO UPDATE SET rating = EXCLUDED.rating, comment = EXCLUDED.comment, is_verified = true, updated_at = now();

  RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_restaurant_review(uuid, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_restaurant_review(uuid, int, text) TO authenticated;

SELECT 'Avis restaurant : unicité (service,client) + RPC submit_restaurant_review (achat vérifié, upsert).' AS status;
