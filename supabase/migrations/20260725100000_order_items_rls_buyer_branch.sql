-- ============================================================================
-- VERSIONNEMENT de l'état RÉEL des policies RLS de public.order_items (prod)
-- ============================================================================
-- Cause racine (commit frontend b7a9eed, 24/07) : la branche acheteur de
-- order_items_party_all compare `orders.customer_id = auth.uid()`. Or
-- `orders.customer_id` RÉFÉRENCE `customers.id` (PAS un id d'utilisateur) — la jointure
-- vers l'utilisateur passe par `customers.user_id`. Cette branche ne matchait donc JAMAIS
-- → l'acheteur ne pouvait pas lire ses lignes → notation produits bloquée en silence.
--
-- Le correctif appliqué en prod (le 24/07, hors migration) = une policy SELECT dédiée
-- `order_items_buyer_select` via le helper `customer_belongs_to_auth_user(customers.id)`.
-- Cette migration REFLÈTE FIDÈLEMENT l'état de prod (les 3 policies) pour qu'une
-- reconstruction depuis zéro produise la même base. Idempotente (DROP IF EXISTS + CREATE).
--
-- ⚠️ On NE corrige PAS ici la branche redondante `o.customer_id = auth.uid()` de
-- order_items_party_all : elle est morte mais inoffensive (l'acheteur passe désormais par
-- order_items_buyer_select ; le vendeur par sa propre branche). D'abord refléter, pas améliorer.
-- ============================================================================

-- 1) Acheteur (SELECT) — LE correctif : accès par customers.user_id (le bon chemin).
DROP POLICY IF EXISTS order_items_buyer_select ON public.order_items;
CREATE POLICY order_items_buyer_select ON public.order_items
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id
        AND customer_belongs_to_auth_user(o.customer_id)
    )
  );

-- 2) Admin/PDG + acheteur (branche morte) + vendeur — état historique, reflété tel quel.
DROP POLICY IF EXISTS order_items_party_all ON public.order_items;
CREATE POLICY order_items_party_all ON public.order_items
  FOR ALL
  TO authenticated
  USING (
    is_admin_or_pdg((SELECT auth.uid()))
    OR EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id
        AND (
          o.customer_id = (SELECT auth.uid())   -- ⚠️ branche morte (customer_id = customers.id)
          OR o.vendor_id IN (SELECT vendors.id FROM public.vendors WHERE vendors.user_id = (SELECT auth.uid()))
        )
    )
  )
  WITH CHECK (
    is_admin_or_pdg((SELECT auth.uid()))
    OR EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id
        AND (
          o.customer_id = (SELECT auth.uid())
          OR o.vendor_id IN (SELECT vendors.id FROM public.vendors WHERE vendors.user_id = (SELECT auth.uid()))
        )
    )
  );

-- 3) Vendeur/agent (ALL) — état historique.
DROP POLICY IF EXISTS vendors_own_order_items ON public.order_items;
CREATE POLICY vendors_own_order_items ON public.order_items
  FOR ALL
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.orders o
      WHERE o.id = order_items.order_id
        AND is_vendor_or_agent(o.vendor_id)
    )
  );
