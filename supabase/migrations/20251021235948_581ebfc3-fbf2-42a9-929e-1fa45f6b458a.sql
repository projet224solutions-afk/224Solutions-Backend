-- Améliorer les politiques RLS pour la gestion des commandes par les vendeurs

-- Supprimer les anciennes politiques pour orders si elles existent
DROP POLICY IF EXISTS "Vendors can view their orders" ON public.orders;
DROP POLICY IF EXISTS "Vendors can update their orders" ON public.orders;
DROP POLICY IF EXISTS "Vendors can update order status" ON public.orders;

-- Créer une politique pour permettre aux vendeurs de voir leurs commandes
CREATE POLICY "vendors_can_view_their_orders"
ON public.orders
FOR SELECT
TO authenticated
USING (
  vendor_id IN (
    SELECT id FROM public.vendors WHERE user_id = auth.uid()
  )
);

-- Créer une politique pour permettre aux vendeurs de mettre à jour leurs commandes
CREATE POLICY "vendors_can_update_their_orders"
ON public.orders
FOR UPDATE
TO authenticated
USING (
  vendor_id IN (
    SELECT id FROM public.vendors WHERE user_id = auth.uid()
  )
)
WITH CHECK (
  vendor_id IN (
    SELECT id FROM public.vendors WHERE user_id = auth.uid()
  )
);

-- Créer une politique pour les clients qui ont passé les commandes
CREATE POLICY "customers_can_view_their_orders"
ON public.orders
FOR SELECT
TO authenticated
USING (
  customer_id IN (
    SELECT id FROM public.customers WHERE user_id = auth.uid()
  )
);

-- Créer un index pour améliorer les performances des requêtes
CREATE INDEX IF NOT EXISTS idx_orders_vendor_id ON public.orders(vendor_id);
CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON public.orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON public.orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_created_at ON public.orders(created_at DESC);