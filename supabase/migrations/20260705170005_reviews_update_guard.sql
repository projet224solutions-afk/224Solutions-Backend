-- ============================================================================
-- 🔒 AVIS : revalider la propriété à l'UPDATE (ferme le re-pointage de note)
-- ----------------------------------------------------------------------------
-- Résidu trouvé par la re-vérif adverse du blindage : les gates INSERT (achat réel)
-- de product_reviews / vendor_ratings sont corrects, MAIS les policies UPDATE ne
-- revalident PAS la propriété de la transaction. Un attaquant ayant 1 avis légitime
-- pouvait UPDATE la ligne (SET vendor_id/product_id = cible) → fausse note « vérifiée »
-- injectée dans l'agrégat (trigger de recalcul). On ajoute le contrôle d'achat au
-- WITH CHECK des deux policies UPDATE. Idempotent (DROP+CREATE).
--
-- Helpers réutilisés : public.user_purchased_product(uuid) (migration 20260705140001),
-- public.user_owns_eligible_order(uuid,uuid) (migration 20260705170001).
-- La réponse vendeur passe par le backend (service_role, hors RLS) → non impactée.
-- ============================================================================

-- ── product_reviews : l'auteur ne peut éditer que si l'achat du produit tient ──
DROP POLICY IF EXISTS "Users can update own reviews" ON public.product_reviews;
CREATE POLICY "Users can update own reviews" ON public.product_reviews
  FOR UPDATE TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id AND public.user_purchased_product(product_id));

-- ── vendor_ratings : l'auteur ne peut éditer que si la commande notée lui appartient ──
DROP POLICY IF EXISTS "vendor_ratings_update_self" ON public.vendor_ratings;
CREATE POLICY "vendor_ratings_update_self" ON public.vendor_ratings
  FOR UPDATE TO authenticated
  USING (customer_id = auth.uid() OR public.is_admin())
  WITH CHECK (
    public.is_admin()
    OR (customer_id = auth.uid() AND public.user_owns_eligible_order(order_id, vendor_id))
  );

SELECT 'Avis : UPDATE revalide l''achat (product_reviews) / la propriété de commande (vendor_ratings) — fini le re-pointage de note.' AS status;
