-- ============================================================================
-- ⭐ AVIS PRODUITS D'UNE BOUTIQUE (pour l'onglet "Avis produits") - 224SOLUTIONS
-- ============================================================================
-- Complète get_shop_reviews (avis boutique = vendor_ratings) par une RPC dédiée
-- aux AVIS PRODUITS approuvés de la boutique, avec nom + pays + photo de l'auteur
-- et le nom du produit (pour regroupement par produit côté UI).
-- ============================================================================

DROP FUNCTION IF EXISTS public.get_shop_product_reviews(uuid);
CREATE OR REPLACE FUNCTION public.get_shop_product_reviews(p_vendor_id uuid)
RETURNS TABLE(
  id uuid,
  rating int,
  title text,
  content text,
  created_at timestamptz,
  verified_purchase boolean,
  vendor_response text,
  vendor_response_at timestamptz,
  product_name text,
  author_name text,
  author_country text,
  author_avatar text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    pr.id,
    pr.rating::int,
    pr.title::text,
    pr.content::text,
    pr.created_at,
    pr.verified_purchase,
    pr.vendor_response::text,
    pr.vendor_response_at,
    prod.name::text AS product_name,
    COALESCE(
      NULLIF(TRIM(CONCAT(pf.first_name, ' ', pf.last_name)), ''),
      pf.full_name,
      'Client'
    ) AS author_name,
    COALESCE(pf.country_code, pf.country)::text AS author_country,
    pf.avatar_url::text AS author_avatar
  FROM public.product_reviews pr
  JOIN public.products prod ON prod.id = pr.product_id
  LEFT JOIN public.profiles pf ON pf.id = pr.user_id
  WHERE prod.vendor_id = p_vendor_id
    AND pr.is_approved = true
  ORDER BY prod.name ASC, pr.created_at DESC
  LIMIT 100;
$$;

GRANT EXECUTE ON FUNCTION public.get_shop_product_reviews(uuid) TO anon, authenticated;
