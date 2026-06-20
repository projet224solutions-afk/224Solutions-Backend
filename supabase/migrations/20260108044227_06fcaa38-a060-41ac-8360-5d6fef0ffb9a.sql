-- Supprimer l'ancienne politique de lecture restrictive
DROP POLICY IF EXISTS "Anyone can read active shared links" ON public.shared_links;

-- Créer une nouvelle politique permettant à TOUS (y compris anon) de lire les liens partagés actifs
CREATE POLICY "Public can read active shared links" 
ON public.shared_links 
FOR SELECT 
TO anon, authenticated
USING (is_active = true);

-- S'assurer que la fonction increment_shared_link_views est accessible publiquement
-- et fonctionne avec SECURITY DEFINER pour bypasser RLS
CREATE OR REPLACE FUNCTION public.increment_shared_link_views(p_short_code TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.shared_links 
  SET views_count = views_count + 1 
  WHERE short_code = p_short_code AND is_active = true;
END;
$$;

-- Accorder les permissions d'exécution à anon et authenticated
GRANT EXECUTE ON FUNCTION public.increment_shared_link_views(TEXT) TO anon, authenticated;