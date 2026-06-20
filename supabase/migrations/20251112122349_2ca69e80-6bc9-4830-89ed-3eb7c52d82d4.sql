-- Mettre à jour la politique d'insertion pour permettre aux clients de créer des commandes
-- La politique actuelle vérifie que customers.user_id = auth.uid() ce qui est correct
-- Mais il faut aussi s'assurer que les clients authentifiés peuvent créer des commandes

-- Supprimer l'ancienne politique restrictive
DROP POLICY IF EXISTS "Vendors and customers can create orders" ON public.orders;

-- Créer une nouvelle politique plus permissive pour la création de commandes
CREATE POLICY "Authenticated users can create orders"
ON public.orders
FOR INSERT
TO authenticated
WITH CHECK (
  -- Les clients peuvent créer des commandes pour eux-mêmes
  EXISTS (
    SELECT 1 FROM customers 
    WHERE customers.id = orders.customer_id 
    AND customers.user_id = auth.uid()
  )
  OR
  -- Les vendeurs peuvent créer des commandes pour leur boutique
  EXISTS (
    SELECT 1 FROM vendors 
    WHERE vendors.id = orders.vendor_id 
    AND vendors.user_id = auth.uid()
  )
);

-- Ajouter une politique pour permettre aux utilisateurs non authentifiés de créer des commandes
-- (pour les commandes guests si nécessaire)
CREATE POLICY "Public can create orders"
ON public.orders
FOR INSERT
TO public
WITH CHECK (true);

-- S'assurer que la table customers a une entrée pour chaque utilisateur
-- Créer les customers manquants pour les utilisateurs existants
INSERT INTO public.customers (user_id, created_at, updated_at)
SELECT p.id, NOW(), NOW()
FROM public.profiles p
WHERE NOT EXISTS (
  SELECT 1 FROM public.customers c WHERE c.user_id = p.id
)
ON CONFLICT DO NOTHING;