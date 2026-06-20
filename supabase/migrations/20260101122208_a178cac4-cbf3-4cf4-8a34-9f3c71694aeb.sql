-- Ajouter une politique pour permettre aux utilisateurs anonymes de voir les produits actifs
CREATE POLICY "anon_view_active_products" 
ON public.products 
FOR SELECT 
TO anon
USING (is_active = true);

-- Faire de même pour les vendors (nécessaire pour les jointures)
CREATE POLICY "anon_view_active_vendors" 
ON public.vendors 
FOR SELECT 
TO anon
USING (is_active = true);

-- Et pour les categories
CREATE POLICY "anon_view_active_categories" 
ON public.categories 
FOR SELECT 
TO anon
USING (is_active = true);