-- Supprimer la politique existante qui ne fonctionne pas pour les utilisateurs non-authentifiés
DROP POLICY IF EXISTS "Public can view published digital products" ON public.digital_products;

-- Créer une politique SELECT pour TOUS les rôles (anon + authenticated) sur les produits publiés
CREATE POLICY "Anyone can view published digital products"
  ON public.digital_products
  FOR SELECT
  TO anon, authenticated
  USING (status = 'published');