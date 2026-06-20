-- Ajouter une politique RLS pour permettre aux vendor_agents de gérer les produits
CREATE POLICY "Vendor agents can manage products"
ON public.products
FOR ALL
USING (
  EXISTS (
    SELECT 1 
    FROM vendor_agents va
    WHERE va.vendor_id = products.vendor_id
    AND va.access_token IS NOT NULL
    AND va.is_active = true
    AND (va.permissions->>'manage_products')::boolean = true
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 
    FROM vendor_agents va
    WHERE va.vendor_id = products.vendor_id
    AND va.access_token IS NOT NULL
    AND va.is_active = true
    AND (va.permissions->>'manage_products')::boolean = true
  )
);