-- ============================================================================
-- ⭐ AVIS DE LA BOUTIQUE = vendor_ratings (≠ avis produits product_reviews)
-- ============================================================================
-- L'écran "Avis" de la boutique doit afficher UNIQUEMENT les avis laissés sur la
-- BOUTIQUE (table vendor_ratings : note + commentaire sur le vendeur), et NON les
-- avis produits (product_reviews, qui restent sur la fiche produit).
--
-- get_shop_reviews renvoie, par avis boutique : note, commentaire, date,
-- réponse du vendeur (PAR avis), + nom, pays et PHOTO de profil du client.
-- SECURITY DEFINER (contourne le RLS profiles) mais n'expose que nom/pays/avatar.
-- ============================================================================

DROP FUNCTION IF EXISTS public.get_shop_reviews(uuid);
CREATE OR REPLACE FUNCTION public.get_shop_reviews(p_vendor_id uuid)
RETURNS TABLE(
  id uuid,
  rating int,
  content text,
  created_at timestamptz,
  vendor_response text,
  vendor_response_at timestamptz,
  author_name text,
  author_country text,
  author_avatar text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    vr.id,
    vr.rating::int,
    vr.comment::text AS content,
    vr.created_at,
    vr.vendor_response::text,
    vr.vendor_response_at,
    COALESCE(
      NULLIF(TRIM(CONCAT(pf.first_name, ' ', pf.last_name)), ''),
      pf.full_name,
      'Client'
    ) AS author_name,
    COALESCE(pf.country_code, pf.country)::text AS author_country,
    pf.avatar_url::text AS author_avatar
  FROM public.vendor_ratings vr
  LEFT JOIN public.profiles pf ON pf.id = vr.customer_id
  WHERE vr.vendor_id = p_vendor_id
  ORDER BY vr.created_at DESC
  LIMIT 50;
$$;

GRANT EXECUTE ON FUNCTION public.get_shop_reviews(uuid) TO anon, authenticated;
