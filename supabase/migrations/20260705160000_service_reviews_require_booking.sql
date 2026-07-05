-- ============================================================================
-- 🔒 AVIS SERVICES RÉSERVÉS AUX VRAIS CLIENTS (preuve de prestation terminée)
-- ----------------------------------------------------------------------------
-- AVANT : ServiceDetail.tsx insérait DIRECTEMENT dans service_reviews (policy
-- permissive "Clients can create reviews" WITH CHECK client_id = auth.uid()).
-- → N'IMPORTE quel utilisateur connecté pouvait noter un service sans jamais y
--   avoir eu recours. Aucune preuve de transaction (contradiction avec la règle
--   « RLS avec PREUVE DE TRANSACTION »).
--
-- APRÈS : l'INSERT direct est INTERDIT (policy permissive retirée → RLS deny par
-- défaut). L'unique voie d'écriture est la RPC submit_service_review (SECURITY
-- DEFINER) qui n'autorise l'avis QUE si le client a une PRESTATION TERMINÉE sur
-- ce professional_service :
--   • restaurant  → restaurant_orders.status IN ('completed','delivered')
--                   (customer_user_id = auth.uid())
--   • réservation → service_bookings.status = 'completed'   (beauté, ménage, BTP…)
--                   (client_id = auth.uid())   ← table RÉELLE (pas de proximity_bookings)
--   • pharmacie   → pharmacy_orders.status IN ('delivered','collected')
--                   (client_id = auth.uid())
-- Un type de service SANS table de transaction identifiable reste FERMÉ : aucune
-- preuve possible → l'avis est refusé (RAISE 'AUCUNE_PRESTATION'). Décision produit
-- assumée : plus d'avis non vérifiés sur les services.
--
-- Upsert sur l'index unique partiel (professional_service_id, client_id) (déjà posé
-- par 20260616250000, recréé ici IF NOT EXISTS pour être auto-portant) + is_verified
-- forcé true. UPDATE/DELETE self conservés. La note moyenne agrégée
-- (professional_services.rating / total_reviews) reste calculée par le trigger SERVEUR
-- existant recompute_service_rating (20260616170000) — JAMAIS écrite par le client.
--
-- ⚠️ Ne PAS confondre avec submit_restaurant_review (20260616250000) : cette RPC-ci
-- est la voie GÉNÉRIQUE de ServiceDetail (couvre restaurant, réservation, pharmacie).
-- ============================================================================

-- 0) Garantir l'index d'upsert (auto-portant si 20260616250000 non appliquée).
CREATE UNIQUE INDEX IF NOT EXISTS uniq_service_reviews_client_service
  ON public.service_reviews (professional_service_id, client_id)
  WHERE client_id IS NOT NULL;

-- 1) RPC : soumettre / mettre à jour un avis service VÉRIFIÉ.
CREATE OR REPLACE FUNCTION public.submit_service_review(
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
  v_uid      uuid := auth.uid();
  v_verified boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'NON_AUTHENTIFIE'; END IF;
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN RAISE EXCEPTION 'NOTE_INVALIDE'; END IF;
  IF p_service_id IS NULL THEN RAISE EXCEPTION 'SERVICE_INVALIDE'; END IF;

  -- Preuve de prestation TERMINÉE (au moins un des trois flux transactionnels).
  -- status castés en ::text pour rester robustes au drift d'enum.
  SELECT
       EXISTS (SELECT 1 FROM public.restaurant_orders
               WHERE professional_service_id = p_service_id
                 AND customer_user_id = v_uid
                 AND status::text IN ('completed','delivered'))
    OR EXISTS (SELECT 1 FROM public.service_bookings
               WHERE professional_service_id = p_service_id
                 AND client_id = v_uid
                 AND status::text = 'completed')
    OR EXISTS (SELECT 1 FROM public.pharmacy_orders
               WHERE pharmacy_id = p_service_id
                 AND client_id = v_uid
                 AND status::text IN ('delivered','collected'))
  INTO v_verified;

  IF NOT v_verified THEN RAISE EXCEPTION 'AUCUNE_PRESTATION'; END IF;

  INSERT INTO public.service_reviews (professional_service_id, client_id, rating, comment, is_verified)
  VALUES (p_service_id, v_uid, p_rating, NULLIF(trim(p_comment), ''), true)
  ON CONFLICT (professional_service_id, client_id) WHERE client_id IS NOT NULL
  DO UPDATE SET rating = EXCLUDED.rating, comment = EXCLUDED.comment, is_verified = true, updated_at = now();

  RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_service_review(uuid, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_service_review(uuid, int, text) TO authenticated;

-- 2) Politiques service_reviews : INSERT direct INTERDIT (RPC-only) ; UPDATE/DELETE self.
--    On retire toutes les policies INSERT permissives connues (20251028 + 20251130).
DROP POLICY IF EXISTS "Clients can create reviews"                ON public.service_reviews;
DROP POLICY IF EXISTS "Les utilisateurs peuvent créer leurs avis" ON public.service_reviews;

DROP POLICY IF EXISTS "Les utilisateurs peuvent modifier leurs avis" ON public.service_reviews;
DROP POLICY IF EXISTS "service_reviews_update_self"                  ON public.service_reviews;
CREATE POLICY "service_reviews_update_self" ON public.service_reviews
  FOR UPDATE TO authenticated
  USING (client_id = auth.uid()) WITH CHECK (client_id = auth.uid());

DROP POLICY IF EXISTS "Les utilisateurs peuvent supprimer leurs avis" ON public.service_reviews;
DROP POLICY IF EXISTS "service_reviews_delete_self"                   ON public.service_reviews;
CREATE POLICY "service_reviews_delete_self" ON public.service_reviews
  FOR DELETE TO authenticated
  USING (client_id = auth.uid());

-- La lecture publique ("Reviews are viewable by everyone", 20251028) reste INCHANGÉE.

SELECT 'Avis services : RPC submit_service_review (preuve prestation restaurant/réservation/pharmacie) + INSERT direct retiré (RPC-only) + UPDATE/DELETE self.' AS status;
