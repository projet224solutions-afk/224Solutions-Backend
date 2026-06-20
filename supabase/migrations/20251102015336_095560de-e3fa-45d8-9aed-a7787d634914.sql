-- Créer une politique RLS pour permettre aux vendeurs de voir leurs clients
-- Un vendeur peut voir les informations des clients qui ont passé des commandes chez lui

CREATE POLICY "Vendors can view their customers through orders"
ON public.customers
FOR SELECT
USING (
  EXISTS (
    SELECT 1 
    FROM public.orders o
    INNER JOIN public.vendors v ON o.vendor_id = v.id
    WHERE o.customer_id = customers.id
    AND v.user_id = auth.uid()
  )
);