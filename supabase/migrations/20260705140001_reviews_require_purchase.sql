-- ============================================================================
-- 🔒 AVIS RÉSERVÉS AUX VRAIS ACHETEURS + drapeaux forcés côté serveur
-- ----------------------------------------------------------------------------
-- FIX 2 : l'INSERT d'un avis produit (product_reviews) OU d'un avis boutique
--         (vendor_ratings) n'est autorisé QUE si l'utilisateur a réellement
--         acheté (≥1 commande éligible).
-- FIX 3 : product_reviews.verified_purchase / is_approved sont FORCÉS par trigger
--         serveur (le client ne les fournit plus).
--
-- ── Noms de colonnes / statuts RÉELS retenus (vérifiés dans les migrations + backend) :
--   • product_reviews.user_id      = auth.uid()               (FK logique profiles/auth.users)
--   • vendor_ratings.customer_id   = auth.uid()               (FK auth.users — migration 20251112223032)
--   • orders.customer_id           = customers.id  (⚠️ PAS auth.uid()) — il faut joindre
--       public.customers c ON c.id = orders.customer_id WHERE c.user_id = auth.uid()
--       (confirmé par backend/src/routes/orders.routes.ts : le customer_id d'une commande
--        est résolu via customers.user_id = auth.uid()).
--   • order_items.product_id       = produit commandé
--   • « commande éligible » = acheteur ayant reçu OU payé :
--       orders.status IN ('delivered','completed')  OU  orders.payment_status = 'paid'
--     Raison : l'UI ouvre la fenêtre d'avis dès que la commande est 'delivered'/'completed'
--     (COD inclus, cf. ClientOrdersList / MyPurchasesOrdersList). Se limiter à
--     payment_status='paid' casserait le paiement à la livraison (statut de paiement
--     souvent 'pending' alors que le colis est bien reçu). On accepte donc les deux.
--     status/payment_status sont castés en ::text pour rester robustes au drift d'enum
--     (la valeur 'completed' n'est pas dans l'enum order_status d'origine).
--
-- ── Pourquoi des fonctions SECURITY DEFINER plutôt qu'un EXISTS inline dans la policy :
--   les sous-requêtes d'une policy RLS sont elles-mêmes soumises au RLS des tables
--   référencées (orders / order_items / customers). Un EXISTS inline pourrait donc être
--   filtré et BLOQUER un acheteur légitime qui n'a pas de SELECT RLS direct sur customers.
--   Les fonctions ci-dessous (DEFINER) contournent ce RLS de lecture, MAIS ne testent
--   QUE les achats de l'appelant (auth.uid() est fixé DANS la fonction) : impossible de
--   sonder les achats d'autrui. Elles ne renvoient qu'un booléen.
-- ============================================================================

-- 1) ── Helpers d'éligibilité (achat réel de l'appelant) ─────────────────────
CREATE OR REPLACE FUNCTION public.user_purchased_product(p_product_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.orders o
    JOIN public.order_items oi ON oi.order_id = o.id
    JOIN public.customers   c  ON c.id = o.customer_id
    WHERE oi.product_id = p_product_id
      AND c.user_id = auth.uid()
      AND (o.status::text IN ('delivered','completed') OR o.payment_status::text = 'paid')
  );
$$;

REVOKE EXECUTE ON FUNCTION public.user_purchased_product(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.user_purchased_product(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.user_purchased_from_vendor(p_vendor_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.orders o
    JOIN public.customers c ON c.id = o.customer_id
    WHERE o.vendor_id = p_vendor_id
      AND c.user_id = auth.uid()
      AND (o.status::text IN ('delivered','completed') OR o.payment_status::text = 'paid')
  );
$$;

REVOKE EXECUTE ON FUNCTION public.user_purchased_from_vendor(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.user_purchased_from_vendor(uuid) TO authenticated;

-- 2) ── product_reviews : INSERT réservé à l'acheteur réel ────────────────────
--    (SELECT public/vendeur/auteur et UPDATE auteur/réponse-vendeur INCHANGÉS —
--     migrations 20251028225022 & 20260610200000).
DROP POLICY IF EXISTS "Users can create reviews"        ON public.product_reviews;
DROP POLICY IF EXISTS "pr_insert_verified_purchaser"    ON public.product_reviews;
CREATE POLICY "pr_insert_verified_purchaser" ON public.product_reviews
  FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = user_id
    AND public.user_purchased_product(product_id)
  );

-- 3) ── product_reviews : FIX 3 — forcer verified_purchase / is_approved serveur
--    L'INSERT n'est possible que pour un acheteur réel (policy ci-dessus) → l'achat
--    EST vérifié. Pas de modération a priori en V1 → is_approved = true (décision
--    documentée ; un futur workflow de modération pourra repasser à false + policy).
CREATE OR REPLACE FUNCTION public.enforce_product_review_flags()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  NEW.verified_purchase := true;
  NEW.is_approved       := true;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.enforce_product_review_flags() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_enforce_product_review_flags ON public.product_reviews;
CREATE TRIGGER trg_enforce_product_review_flags
  BEFORE INSERT ON public.product_reviews
  FOR EACH ROW EXECUTE FUNCTION public.enforce_product_review_flags();

-- 4) ── vendor_ratings : INSERT réservé à l'acheteur réel, UPDATE/DELETE = self ─
--    Remplace la policy FOR ALL "vendor_ratings_customer_manage" (migration
--    20260606110000) par 3 policies (INSERT gaté / UPDATE self / DELETE self).
--    La lecture publique ("Les notes sont visibles par tous") reste INCHANGÉE.
--    Le comportement customer (self) + is_admin est PRÉSERVÉ à l'identique pour
--    UPDATE/DELETE → la réponse vendeur (via is_admin/backend) n'est pas cassée.
DROP POLICY IF EXISTS "vendor_ratings_customer_manage"          ON public.vendor_ratings;
DROP POLICY IF EXISTS "Les clients peuvent noter leurs commandes" ON public.vendor_ratings;
DROP POLICY IF EXISTS "Les clients peuvent modifier leurs notes"  ON public.vendor_ratings;

DROP POLICY IF EXISTS "vendor_ratings_insert_verified_buyer" ON public.vendor_ratings;
CREATE POLICY "vendor_ratings_insert_verified_buyer" ON public.vendor_ratings
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_admin()
    OR (
      customer_id = auth.uid()
      AND public.user_purchased_from_vendor(vendor_id)
    )
  );

DROP POLICY IF EXISTS "vendor_ratings_update_self" ON public.vendor_ratings;
CREATE POLICY "vendor_ratings_update_self" ON public.vendor_ratings
  FOR UPDATE TO authenticated
  USING (customer_id = auth.uid() OR public.is_admin())
  WITH CHECK (customer_id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS "vendor_ratings_delete_self" ON public.vendor_ratings;
CREATE POLICY "vendor_ratings_delete_self" ON public.vendor_ratings
  FOR DELETE TO authenticated
  USING (customer_id = auth.uid() OR public.is_admin());

SELECT 'Avis réservés aux vrais acheteurs : product_reviews.INSERT + vendor_ratings.INSERT gatés (achat delivered/completed OU payment_status=paid) + verified_purchase/is_approved forcés serveur.' AS status;
