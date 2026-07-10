-- ============================================================================
-- ⭐ NOTATION DES LIVREURS (marketplace) — table + RPC vérifiée + agrégat serveur
-- ----------------------------------------------------------------------------
-- Constat : aucune table ne permettait de noter le LIVREUR d'une commande.
-- On ajoute delivery_driver_ratings (1 note par commande, order_id UNIQUE),
-- réservée au CLIENT PROPRIÉTAIRE d'une commande LIVRÉE par un livreur assigné,
-- via RPC SECURITY DEFINER. La note moyenne du livreur vit sur drivers.rating
-- (déjà affichée sur le dashboard livreur, DriverProfile) ; on ajoute
-- drivers.ratings_count. L'agrégat est recalculé par trigger SERVEUR
-- (recompute_driver_delivery_rating) — JAMAIS écrit par le client.
--
-- ── Convention driver_id (vérifiée) : deliveries.driver_id = profiles.id = auth.uid()
--    du livreur (cf. backend/src/routes/delivery.routes.ts, en-tête + accept_delivery
--    appelé avec p_driver_id = userId). drivers.user_id = ce même auth.uid().
--    → l'agrégat cible drivers WHERE user_id = <driver_id noté>.
--    → delivery_driver_ratings.driver_id STOCKE l'auth.uid() du livreur.
-- ── Propriété commande : orders.customer_id = customers.id ; customers.user_id = auth.uid()
--    (même chaîne de preuve d'achat que 20260705140001).
-- ── Preuve de course : une ligne deliveries pour cette commande, status='delivered',
--    driver_id NON nul.
-- ============================================================================

-- 0) Compteur d'avis livreur (la moyenne réutilise drivers.rating déjà existant).
ALTER TABLE public.drivers ADD COLUMN IF NOT EXISTS ratings_count integer NOT NULL DEFAULT 0;

-- 1) Table des notes livreur (1 par commande).
CREATE TABLE IF NOT EXISTS public.delivery_driver_ratings (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id  uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  order_id   uuid NOT NULL UNIQUE REFERENCES public.orders(id) ON DELETE CASCADE,
  client_id  uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  rating     int  NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment    text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_delivery_driver_ratings_driver ON public.delivery_driver_ratings(driver_id);
CREATE INDEX IF NOT EXISTS idx_delivery_driver_ratings_client ON public.delivery_driver_ratings(client_id);

ALTER TABLE public.delivery_driver_ratings ENABLE ROW LEVEL SECURITY;

-- 2) RLS — lecture livreur noté + admin (+ auteur pour relire sa propre note,
--    sans fuite) ; INSERT via RPC-only ; UPDATE/DELETE = auteur ; service_role plein accès.
DROP POLICY IF EXISTS ddr_read_driver_admin_author ON public.delivery_driver_ratings;
CREATE POLICY ddr_read_driver_admin_author ON public.delivery_driver_ratings
  FOR SELECT TO authenticated
  USING (driver_id = auth.uid() OR client_id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS ddr_update_self ON public.delivery_driver_ratings;
CREATE POLICY ddr_update_self ON public.delivery_driver_ratings
  FOR UPDATE TO authenticated
  USING (client_id = auth.uid()) WITH CHECK (client_id = auth.uid());

DROP POLICY IF EXISTS ddr_delete_self ON public.delivery_driver_ratings;
CREATE POLICY ddr_delete_self ON public.delivery_driver_ratings
  FOR DELETE TO authenticated
  USING (client_id = auth.uid());

DROP POLICY IF EXISTS ddr_service_role ON public.delivery_driver_ratings;
CREATE POLICY ddr_service_role ON public.delivery_driver_ratings
  FOR ALL TO service_role USING (true) WITH CHECK (true);
-- (Pas de policy INSERT pour authenticated → insert direct impossible : RPC-only.)

-- 3) RPC : noter le livreur d'une commande livrée (client propriétaire).
CREATE OR REPLACE FUNCTION public.submit_delivery_rating(
  p_order_id uuid,
  p_rating   int,
  p_comment  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_owns      boolean;
  v_driver_id uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'NON_AUTHENTIFIE'; END IF;
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN RAISE EXCEPTION 'NOTE_INVALIDE'; END IF;
  IF p_order_id IS NULL THEN RAISE EXCEPTION 'COMMANDE_INVALIDE'; END IF;

  -- La commande appartient à l'appelant (orders.customer_id -> customers.user_id).
  SELECT EXISTS (
    SELECT 1 FROM public.orders o
    JOIN public.customers c ON c.id = o.customer_id
    WHERE o.id = p_order_id AND c.user_id = v_uid
  ) INTO v_owns;
  IF NOT v_owns THEN RAISE EXCEPTION 'COMMANDE_NON_AUTORISEE'; END IF;

  -- Livraison terminée avec un livreur assigné.
  SELECT driver_id INTO v_driver_id
  FROM public.deliveries
  WHERE order_id = p_order_id
    AND driver_id IS NOT NULL
    AND status::text = 'delivered'
  ORDER BY completed_at DESC NULLS LAST
  LIMIT 1;
  IF v_driver_id IS NULL THEN RAISE EXCEPTION 'AUCUN_LIVREUR'; END IF;

  INSERT INTO public.delivery_driver_ratings (driver_id, order_id, client_id, rating, comment)
  VALUES (v_driver_id, p_order_id, v_uid, p_rating, NULLIF(trim(p_comment), ''))
  ON CONFLICT (order_id)
  DO UPDATE SET rating = EXCLUDED.rating, comment = EXCLUDED.comment, updated_at = now();

  RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_delivery_rating(uuid, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_delivery_rating(uuid, int, text) TO authenticated;

-- 4) Agrégat SERVEUR : drivers.rating + ratings_count recalculés par trigger.
CREATE OR REPLACE FUNCTION public.recompute_driver_delivery_rating()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver uuid := COALESCE(NEW.driver_id, OLD.driver_id);
BEGIN
  IF v_driver IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;
  UPDATE public.drivers d
  SET rating        = COALESCE((SELECT ROUND(AVG(rating)::numeric, 1) FROM public.delivery_driver_ratings WHERE driver_id = v_driver), 0),
      ratings_count = (SELECT COUNT(*) FROM public.delivery_driver_ratings WHERE driver_id = v_driver),
      updated_at    = now()
  WHERE d.user_id = v_driver;
  RETURN COALESCE(NEW, OLD);
END;
$$;

-- Trigger interne : non appelable directement via PostgREST.
REVOKE EXECUTE ON FUNCTION public.recompute_driver_delivery_rating() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_recompute_driver_delivery_rating ON public.delivery_driver_ratings;
CREATE TRIGGER trg_recompute_driver_delivery_rating
  AFTER INSERT OR UPDATE OR DELETE ON public.delivery_driver_ratings
  FOR EACH ROW EXECUTE FUNCTION public.recompute_driver_delivery_rating();

SELECT 'Notation livreurs : table delivery_driver_ratings + RPC submit_delivery_rating (commande livrée du client) + drivers.ratings_count + trigger agrégat drivers.rating.' AS status;
