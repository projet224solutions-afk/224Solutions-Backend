-- ============================================================================
-- 🔒 CORRECTIF : lier l'avis boutique (vendor_ratings) à LA commande du notateur
-- ----------------------------------------------------------------------------
-- BUG (audit 2026-07-05) : la policy vendor_ratings_insert_verified_buyer
-- (20260705140001) vérifiait seulement user_purchased_from_vendor(vendor_id) —
-- « l'appelant a ≥1 commande éligible chez ce vendeur » — sans lier la ligne
-- insérée (order_id) à une commande de l'appelant. Comme la table n'a qu'un
-- UNIQUE(order_id, customer_id) (PAS UNIQUE(vendor_id, customer_id)), un acheteur
-- ayant UNE commande livrée chez V pouvait insérer PLUSIEURS avis pour V en
-- fournissant des order_id distincts → il pesait N fois dans AVG(rating).
--
-- FIX : nouveau helper user_owns_eligible_order(p_order_id, p_vendor_id) qui vérifie
-- que la commande référencée appartient à l'appelant ET au vendeur noté ET est
-- éligible (delivered/completed OU payée). La policy INSERT exige désormais que
-- order_id soit une commande de l'appelant chez ce vendeur → 1 avis par commande.
-- SECURITY DEFINER + search_path (contourne le RLS de lecture d'orders/customers,
-- mais borné à auth.uid()). Idempotent (CREATE OR REPLACE / DROP+CREATE policy).
-- ============================================================================

-- 1) ── Helper : la commande est-elle celle de l'appelant chez ce vendeur, éligible ? ──
CREATE OR REPLACE FUNCTION public.user_owns_eligible_order(p_order_id uuid, p_vendor_id uuid)
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
    WHERE o.id = p_order_id
      AND o.vendor_id = p_vendor_id
      AND c.user_id = auth.uid()
      AND (o.status::text IN ('delivered','completed') OR o.payment_status::text = 'paid')
  );
$$;

REVOKE EXECUTE ON FUNCTION public.user_owns_eligible_order(uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.user_owns_eligible_order(uuid, uuid) TO authenticated;

-- 2) ── vendor_ratings : INSERT lié à la commande du notateur ─────────────────
DROP POLICY IF EXISTS "vendor_ratings_insert_verified_buyer" ON public.vendor_ratings;
CREATE POLICY "vendor_ratings_insert_verified_buyer" ON public.vendor_ratings
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_admin()
    OR (
      customer_id = auth.uid()
      AND public.user_owns_eligible_order(order_id, vendor_id)
    )
  );

SELECT 'FIX vendor_ratings : INSERT lié à la commande (user_owns_eligible_order) → 1 avis par commande, plus de gonflage de note.' AS status;
