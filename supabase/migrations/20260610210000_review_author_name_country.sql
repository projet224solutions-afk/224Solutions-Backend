-- ============================================================================
-- ⭐ NOM + PAYS DE L'AUTEUR D'UN AVIS - 224SOLUTIONS
-- ============================================================================
-- Affiche le nom et le drapeau du pays du client qui a laissé l'avis :
--   • get_shop_reviews(vendor) : PUBLIC (page boutique) — avis approuvés + nom + pays.
--   • get_review_author_names(ids) : VENDEUR — étendu pour renvoyer aussi le pays.
-- SECURITY DEFINER pour contourner le RLS profiles, mais n'expose QUE le nom et le
-- pays (pas le téléphone/email), et seulement pour les avis concernés.
-- ============================================================================

-- 1) RPC PUBLIQUE : avis d'une boutique (avec nom + pays de l'auteur)
DROP FUNCTION IF EXISTS public.get_shop_reviews(uuid);
CREATE OR REPLACE FUNCTION public.get_shop_reviews(p_vendor_id uuid)
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
  author_country text
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
    COALESCE(pf.country_code, pf.country)::text AS author_country
  FROM public.product_reviews pr
  JOIN public.products prod ON prod.id = pr.product_id
  LEFT JOIN public.profiles pf ON pf.id = pr.user_id
  WHERE prod.vendor_id = p_vendor_id
    AND pr.is_approved = true
  ORDER BY pr.created_at DESC
  LIMIT 50;
$$;

GRANT EXECUTE ON FUNCTION public.get_shop_reviews(uuid) TO anon, authenticated;

-- 2) RPC VENDEUR : nom + pays (remplace l'ancienne signature)
DROP FUNCTION IF EXISTS public.get_review_author_names(uuid[]);
CREATE OR REPLACE FUNCTION public.get_review_author_names(p_review_ids uuid[])
RETURNS TABLE(review_id uuid, author_name text, author_country text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    pr.id AS review_id,
    COALESCE(
      NULLIF(TRIM(CONCAT(pf.first_name, ' ', pf.last_name)), ''),
      pf.full_name,
      'Client'
    ) AS author_name,
    COALESCE(pf.country_code, pf.country)::text AS author_country
  FROM public.product_reviews pr
  JOIN public.products prod ON prod.id = pr.product_id
  JOIN public.vendors v ON v.id = prod.vendor_id
  LEFT JOIN public.profiles pf ON pf.id = pr.user_id
  WHERE pr.id = ANY(p_review_ids)
    AND v.user_id = auth.uid();
$$;

GRANT EXECUTE ON FUNCTION public.get_review_author_names(uuid[]) TO authenticated;
