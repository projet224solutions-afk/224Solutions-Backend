-- Supprimer les anciennes policies problématiques sur products
DROP POLICY IF EXISTS "Vendor agents can manage products" ON public.products;

-- Recréer la policy pour lecture publique des produits actifs
DROP POLICY IF EXISTS "Everyone can view active products" ON public.products;
CREATE POLICY "Everyone can view active products" 
ON public.products 
FOR SELECT 
TO public
USING (is_active = true);

-- Policy pour permettre aux agents (non-authentifiés Supabase) de lire les produits
-- L'application filtre par vendor_id côté client
DROP POLICY IF EXISTS "Anon can read vendor products" ON public.products;
CREATE POLICY "Anon can read vendor products" 
ON public.products 
FOR SELECT 
TO anon
USING (true);

-- Policy pour les vendeurs authentifiés - gestion complète de leurs produits
DROP POLICY IF EXISTS "Vendors can manage own products" ON public.products;
CREATE POLICY "Vendors can manage own products" 
ON public.products 
FOR ALL 
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.vendors v
    WHERE v.id = products.vendor_id
    AND v.user_id = auth.uid()
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.vendors v
    WHERE v.id = products.vendor_id
    AND v.user_id = auth.uid()
  )
);