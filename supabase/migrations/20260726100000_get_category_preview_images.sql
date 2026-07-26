-- ============================================================================
-- get_category_preview_images — ≤ N premières images par catégorie, bornées CÔTÉ BASE
-- ============================================================================
-- Avant : la page Proximité chargeait `products!inner(id, images)` → TOUS les tableaux
-- `images` de TOUS les produits de chaque catégorie étaient transférés juste pour en garder
-- 4 (réponse ×8 : 2,6 → 21,3 KB ; explose à 5000 produits/catégorie).
--
-- Ici : count agrégé côté client (products!inner(count), léger) + CETTE fonction qui renvoie,
-- pour un ensemble de catégories, au plus `p_per_cat` premières images (row_number DB-side).
-- products.images est un text[] → p.images[1] = 1re image du produit.
--
-- SECURITY INVOKER (défaut) : respecte la RLS de `products` (anon ne voit que les actifs) ;
-- le filtre is_active=true reste explicite pour la cohérence. Aucune donnée sensible (URLs
-- d'images de produits publics).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_category_preview_images(
  p_category_ids uuid[],
  p_per_cat int DEFAULT 4
)
RETURNS TABLE(category_id uuid, image_url text)
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT t.category_id, t.image_url
  FROM (
    SELECT p.category_id,
           p.images[1] AS image_url,
           row_number() OVER (
             PARTITION BY p.category_id
             ORDER BY p.created_at DESC NULLS LAST
           ) AS rn
    FROM public.products p
    WHERE p.category_id = ANY(p_category_ids)
      AND p.is_active = true
      AND p.images IS NOT NULL
      AND array_length(p.images, 1) >= 1
      AND p.images[1] IS NOT NULL
      AND btrim(p.images[1]) <> ''
  ) t
  WHERE t.rn <= LEAST(GREATEST(COALESCE(p_per_cat, 4), 1), 8)   -- borne dure 1..8
  ORDER BY t.category_id, t.rn;
$$;

REVOKE ALL ON FUNCTION public.get_category_preview_images(uuid[], int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_category_preview_images(uuid[], int)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_category_preview_images(uuid[], int) IS
  'Renvoie ≤ p_per_cat (1..8) premières images (text[][1]) des produits actifs par catégorie, pour la page Proximité. Évite de transférer tous les images[] côté client.';
