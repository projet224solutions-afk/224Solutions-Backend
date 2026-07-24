-- 🔴 Fix RLS : l'ACHETEUR ne pouvait pas lire les lignes de SA PROPRE commande (order_items).
--
-- Symptôme : à la confirmation de réception, le dialog de notation ne proposait JAMAIS l'étape
-- « noter les produits » — il sautait directement à la notation boutique.
--
-- Cause : la table `orders` a la bonne politique (`customer_belongs_to_auth_user(customer_id)`),
-- MAIS la politique de `order_items` (`order_items_party_all`) autorisait l'acheteur via
-- `orders.customer_id = auth.uid()`. Or `orders.customer_id` est un `customers.id` (FK vers la
-- table customers), PAS un id d'authentification → cette condition n'est JAMAIS vraie. L'acheteur
-- ne pouvait donc pas lire ses lignes → requête vide → étape produits sautée en silence.
--
-- Correctif : politique **SELECT-only** dédiée à l'acheteur, via le même helper que `orders`.
-- SELECT uniquement (surtout PAS ALL) → l'acheteur peut LIRE ses lignes mais ne peut ni les
-- insérer, ni les modifier, ni les supprimer. On ne touche pas aux politiques existantes
-- (admin/vendeur conservées). customer_belongs_to_auth_user est STABLE SECURITY DEFINER.

DROP POLICY IF EXISTS order_items_buyer_select ON public.order_items;
CREATE POLICY order_items_buyer_select ON public.order_items
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.id = order_items.order_id
        AND customer_belongs_to_auth_user(o.customer_id)
    )
  );
